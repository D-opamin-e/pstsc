#include "pstsc_rdp.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/rail.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/codec/region.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/input.h>
#include <freerdp/rail.h>
#include <freerdp/scancode.h>
#include <freerdp/window.h>
#include <winpr/input.h>
#include <winpr/string.h>
#include <winpr/synch.h>

#define WS_MAXIMIZE 0x01000000

typedef struct
{
	uint32_t windowId;
	uint32_t ownerWindowId;
	uint32_t style;
	uint32_t extendedStyle;
	uint32_t showState;
	char* title;
	int32_t x;
	int32_t y;
	uint32_t width;
	uint32_t height;
	int32_t clientOffsetX;
	int32_t clientOffsetY;
	int32_t windowClientDeltaX;
	int32_t windowClientDeltaY;
	int32_t visibleOffsetX;
	int32_t visibleOffsetY;
	uint32_t numVisibilityRects;
	RECTANGLE_16* visibilityRects;
} PstscWindow;

typedef struct
{
	uint8_t cacheId;
	uint16_t cacheEntry;
	uint32_t width;
	uint32_t height;
	uint8_t* pixels; /* BGRA32, top-down */
} PstscIcon;

struct PstscClient
{
	PstscCallbacks cb;
	rdpContext* context;
	RailClientContext* rail;
	pthread_t thread;
	bool threadStarted;
	atomic_bool connected;
	atomic_bool railStarted;

	int32_t workAreaX;
	int32_t workAreaY;
	uint32_t workAreaWidth;
	uint32_t workAreaHeight;

	/* Only touched on the RDP thread. */
	PstscWindow* windows;
	size_t windowCount;
	size_t windowCapacity;

	/* Converted icons the server may refer to later by (cacheId, cacheEntry). */
	PstscIcon* icons;
	size_t iconCount;
	size_t iconCapacity;
};

typedef struct
{
	rdpClientContext common;
	PstscClient* client;
} PstscContext;

static PstscClient* client_from(rdpContext* context)
{
	return context ? ((PstscContext*)context)->client : NULL;
}

static void notify_state(PstscClient* client, PstscState state, uint32_t errorCode,
                         const char* message)
{
	if (client->cb.stateChanged)
		client->cb.stateChanged(client->cb.user, state, errorCode, message ? message : "");
}

/* ---- Window table ---- */

static PstscWindow* window_find(PstscClient* client, uint32_t windowId)
{
	for (size_t i = 0; i < client->windowCount; i++)
	{
		if (client->windows[i].windowId == windowId)
			return &client->windows[i];
	}
	return NULL;
}

static PstscWindow* window_find_or_add(PstscClient* client, uint32_t windowId)
{
	PstscWindow* window = window_find(client, windowId);
	if (window)
		return window;

	if (client->windowCount == client->windowCapacity)
	{
		size_t capacity = client->windowCapacity ? client->windowCapacity * 2 : 16;
		PstscWindow* grown = realloc(client->windows, capacity * sizeof(PstscWindow));
		if (!grown)
			return NULL;
		client->windows = grown;
		client->windowCapacity = capacity;
	}

	window = &client->windows[client->windowCount++];
	memset(window, 0, sizeof(*window));
	window->windowId = windowId;
	return window;
}

static void window_release(PstscWindow* window)
{
	free(window->title);
	free(window->visibilityRects);
}

static void window_remove(PstscClient* client, uint32_t windowId)
{
	for (size_t i = 0; i < client->windowCount; i++)
	{
		if (client->windows[i].windowId != windowId)
			continue;
		window_release(&client->windows[i]);
		client->windows[i] = client->windows[--client->windowCount];
		return;
	}
}

static void windows_clear(PstscClient* client)
{
	for (size_t i = 0; i < client->windowCount; i++)
		window_release(&client->windows[i]);
	client->windowCount = 0;
}

/* Visible bounding box relative to the window origin (same offset math as xfreerdp). */
static void window_visible_box(const PstscWindow* window, PstscWindowInfo* info)
{
	info->visibleX = 0;
	info->visibleY = 0;
	info->visibleWidth = 0;
	info->visibleHeight = 0;

	if ((window->style & WS_MAXIMIZE) || window->numVisibilityRects == 0)
		return;

	const int32_t offsetX =
	    window->visibleOffsetX - (window->clientOffsetX - window->windowClientDeltaX);
	const int32_t offsetY =
	    window->visibleOffsetY - (window->clientOffsetY - window->windowClientDeltaY);

	int32_t left = INT32_MAX;
	int32_t top = INT32_MAX;
	int32_t right = INT32_MIN;
	int32_t bottom = INT32_MIN;
	for (uint32_t i = 0; i < window->numVisibilityRects; i++)
	{
		const RECTANGLE_16* r = &window->visibilityRects[i];
		/* Coordinates may be negative INT16 values stored in UINT16 fields. */
		const int32_t l = (int16_t)r->left + offsetX;
		const int32_t t = (int16_t)r->top + offsetY;
		const int32_t rr = (int16_t)r->right + offsetX;
		const int32_t b = (int16_t)r->bottom + offsetY;
		left = l < left ? l : left;
		top = t < top ? t : top;
		right = rr > right ? rr : right;
		bottom = b > bottom ? b : bottom;
	}

	left = left < 0 ? 0 : left;
	top = top < 0 ? 0 : top;
	right = right > (int32_t)window->width ? (int32_t)window->width : right;
	bottom = bottom > (int32_t)window->height ? (int32_t)window->height : bottom;
	if (right <= left || bottom <= top)
		return;

	info->visibleX = left;
	info->visibleY = top;
	info->visibleWidth = (uint32_t)(right - left);
	info->visibleHeight = (uint32_t)(bottom - top);
}

static void window_emit(PstscClient* client, const PstscWindow* window)
{
	if (!client->cb.windowChanged)
		return;

	PstscWindowInfo info = { 0 };
	info.windowId = window->windowId;
	info.ownerWindowId = window->ownerWindowId;
	info.style = window->style;
	info.extendedStyle = window->extendedStyle;
	info.showState = window->showState;
	info.title = window->title ? window->title : "";
	info.x = window->x;
	info.y = window->y;
	info.width = window->width;
	info.height = window->height;
	window_visible_box(window, &info);
	client->cb.windowChanged(client->cb.user, &info);
}

/* ---- Window orders (RAIL) ---- */

static BOOL on_window_common(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                             const WINDOW_STATE_ORDER* state)
{
	PstscClient* client = client_from(context);
	if (!client || !orderInfo || !state)
		return FALSE;

	PstscWindow* window = window_find_or_add(client, orderInfo->windowId);
	if (!window)
		return FALSE;

	const UINT32 flags = orderInfo->fieldFlags;
	if (flags & WINDOW_ORDER_FIELD_OWNER)
		window->ownerWindowId = state->ownerWindowId;
	if (flags & WINDOW_ORDER_FIELD_STYLE)
	{
		window->style = state->style;
		window->extendedStyle = state->extendedStyle;
	}
	if (flags & WINDOW_ORDER_FIELD_SHOW)
		window->showState = state->showState;
	if (flags & WINDOW_ORDER_FIELD_TITLE)
	{
		free(window->title);
		window->title = NULL;
		if (state->titleInfo.length > 0)
			window->title = ConvertWCharNToUtf8Alloc(
			    state->titleInfo.string, state->titleInfo.length / sizeof(WCHAR), NULL);
	}
	if (flags & WINDOW_ORDER_FIELD_CLIENT_AREA_OFFSET)
	{
		window->clientOffsetX = state->clientOffsetX;
		window->clientOffsetY = state->clientOffsetY;
	}
	if (flags & WINDOW_ORDER_FIELD_WND_CLIENT_DELTA)
	{
		window->windowClientDeltaX = state->windowClientDeltaX;
		window->windowClientDeltaY = state->windowClientDeltaY;
	}
	if (flags & WINDOW_ORDER_FIELD_WND_OFFSET)
	{
		window->x = state->windowOffsetX;
		window->y = state->windowOffsetY;
	}
	if (flags & WINDOW_ORDER_FIELD_WND_SIZE)
	{
		window->width = state->windowWidth;
		window->height = state->windowHeight;
	}
	if (flags & WINDOW_ORDER_FIELD_VIS_OFFSET)
	{
		window->visibleOffsetX = state->visibleOffsetX;
		window->visibleOffsetY = state->visibleOffsetY;
	}
	if (flags & WINDOW_ORDER_FIELD_VISIBILITY)
	{
		free(window->visibilityRects);
		window->visibilityRects = NULL;
		window->numVisibilityRects = 0;
		if (state->numVisibilityRects > 0)
		{
			window->visibilityRects = calloc(state->numVisibilityRects, sizeof(RECTANGLE_16));
			if (window->visibilityRects)
			{
				memcpy(window->visibilityRects, state->visibilityRects,
				       state->numVisibilityRects * sizeof(RECTANGLE_16));
				window->numVisibilityRects = state->numVisibilityRects;
			}
		}
	}

	window_emit(client, window);
	return TRUE;
}

static BOOL on_window_delete(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	PstscClient* client = client_from(context);
	if (!client || !orderInfo)
		return FALSE;

	window_remove(client, orderInfo->windowId);
	if (client->cb.windowRemoved)
		client->cb.windowRemoved(client->cb.user, orderInfo->windowId);
	return TRUE;
}

static void icons_clear(PstscClient* client)
{
	for (size_t i = 0; i < client->iconCount; i++)
		free(client->icons[i].pixels);
	client->iconCount = 0;
}

static PstscIcon* icon_find(PstscClient* client, uint8_t cacheId, uint16_t cacheEntry)
{
	for (size_t i = 0; i < client->iconCount; i++)
	{
		if (client->icons[i].cacheId == cacheId && client->icons[i].cacheEntry == cacheEntry)
			return &client->icons[i];
	}
	return NULL;
}

static void icon_emit(PstscClient* client, uint32_t windowId, const PstscIcon* icon)
{
	if (client->cb.windowIcon && icon->pixels)
		client->cb.windowIcon(client->cb.user, windowId, icon->width, icon->height, icon->pixels);
}

static BOOL on_window_icon(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                           const WINDOW_ICON_ORDER* order)
{
	PstscClient* client = client_from(context);
	const ICON_INFO* info = order ? order->iconInfo : NULL;
	if (!client || !orderInfo || !info || info->width == 0 || info->height == 0 ||
	    info->width > 256 || info->height > 256)
		return TRUE;

	PstscIcon icon = { .cacheId = (uint8_t)info->cacheId,
		               .cacheEntry = (uint16_t)info->cacheEntry,
		               .width = info->width,
		               .height = info->height };
	icon.pixels = calloc((size_t)info->width * info->height, 4);
	if (!icon.pixels)
		return TRUE;
	if (!freerdp_image_copy_from_icon_data(
	        icon.pixels, PIXEL_FORMAT_BGRA32, info->width * 4, 0, 0, (UINT16)info->width,
	        (UINT16)info->height, info->bitsColor, (UINT16)info->cbBitsColor, info->bitsMask,
	        (UINT16)info->cbBitsMask, info->colorTable, (UINT16)info->cbColorTable, info->bpp))
	{
		free(icon.pixels);
		return TRUE;
	}
	icon_emit(client, orderInfo->windowId, &icon);

	/* 0xFFFF: the server will not refer to this icon again. */
	if (info->cacheEntry == 0xFFFF)
	{
		free(icon.pixels);
		return TRUE;
	}
	PstscIcon* slot = icon_find(client, icon.cacheId, icon.cacheEntry);
	if (!slot && client->iconCount == client->iconCapacity)
	{
		size_t capacity = client->iconCapacity ? client->iconCapacity * 2 : 16;
		PstscIcon* grown = realloc(client->icons, capacity * sizeof(PstscIcon));
		if (!grown)
		{
			free(icon.pixels);
			return TRUE;
		}
		client->icons = grown;
		client->iconCapacity = capacity;
	}
	if (slot)
		free(slot->pixels);
	else
		slot = &client->icons[client->iconCount++];
	*slot = icon;
	return TRUE;
}

static BOOL on_window_cached_icon(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                  const WINDOW_CACHED_ICON_ORDER* order)
{
	PstscClient* client = client_from(context);
	if (!client || !orderInfo || !order)
		return TRUE;
	const PstscIcon* icon = icon_find(client, (uint8_t)order->cachedIcon.cacheId,
	                                  (uint16_t)order->cachedIcon.cacheEntry);
	if (icon)
		icon_emit(client, orderInfo->windowId, icon);
	return TRUE;
}

static char* unicode_string_to_utf8(const RAIL_UNICODE_STRING* string)
{
	char* utf8 = NULL;
	if (string->length > 0 && string->string)
		utf8 = ConvertWCharNToUtf8Alloc(string->string, string->length / sizeof(WCHAR), NULL);
	return utf8 ? utf8 : strdup("");
}

static BOOL on_notify_icon(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                           const NOTIFY_ICON_STATE_ORDER* state)
{
	PstscClient* client = client_from(context);
	if (!client || !orderInfo || !state || !client->cb.trayBalloon)
		return TRUE;
	if (!(orderInfo->fieldFlags & WINDOW_ORDER_FIELD_NOTIFY_INFO_TIP))
		return TRUE;

	char* title = unicode_string_to_utf8(&state->infoTip.title);
	char* text = unicode_string_to_utf8(&state->infoTip.text);
	if (title && text && (*title || *text))
		client->cb.trayBalloon(client->cb.user, orderInfo->windowId, orderInfo->notifyIconId, title,
		                       text);
	free(title);
	free(text);
	return TRUE;
}

static BOOL on_notify_icon_delete(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	(void)context;
	(void)orderInfo;
	return TRUE;
}

static UINT send_work_area(PstscClient* client)
{
	if (!client->rail || client->workAreaWidth == 0 || client->workAreaHeight == 0)
		return CHANNEL_RC_OK;

	RAIL_SYSPARAM_ORDER sysparam = { 0 };
	sysparam.param = SPI_SET_WORK_AREA;
	sysparam.params = SPI_MASK_SET_WORK_AREA;
	sysparam.workArea.left = (UINT16)client->workAreaX;
	sysparam.workArea.top = (UINT16)client->workAreaY;
	sysparam.workArea.right = (UINT16)(client->workAreaX + (int32_t)client->workAreaWidth);
	sysparam.workArea.bottom = (UINT16)(client->workAreaY + (int32_t)client->workAreaHeight);
	return client->rail->ClientSystemParam(client->rail, &sysparam);
}

static BOOL on_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                 const MONITORED_DESKTOP_ORDER* desktop)
{
	(void)desktop;
	PstscClient* client = client_from(context);
	if (!client || !orderInfo)
		return FALSE;

	/* The server finished describing its windows: now launch the requested program. */
	if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) && client->rail &&
	    !atomic_load(&client->railStarted))
	{
		atomic_store(&client->railStarted, true);
		fprintf(stderr, "[pstsc] remote desktop ready, launching program\n");
		if (client_rail_server_start_cmd(client->rail) != CHANNEL_RC_OK)
			return FALSE;
		if (send_work_area(client) != CHANNEL_RC_OK)
			return FALSE;
		notify_state(client, PSTSC_STATE_READY, 0, NULL);
	}
	return TRUE;
}

static BOOL on_non_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	(void)context;
	(void)orderInfo;
	return TRUE;
}

/* ---- RAIL channel ---- */

static UINT on_rail_exec_result(RailClientContext* rail, const RAIL_EXEC_RESULT_ORDER* result)
{
	PstscClient* client = rail->custom;
	if (!client || !result || !client->cb.execResult)
		return CHANNEL_RC_OK;

	char* program = NULL;
	if (result->exeOrFile.length > 0)
		program = ConvertWCharNToUtf8Alloc(result->exeOrFile.string,
		                                   result->exeOrFile.length / sizeof(WCHAR), NULL);
	client->cb.execResult(client->cb.user, result->execResult, result->rawResult,
	                      program ? program : "");
	free(program);
	return CHANNEL_RC_OK;
}

static UINT on_rail_server_system_param(RailClientContext* rail, const RAIL_SYSPARAM_ORDER* param)
{
	(void)rail;
	(void)param;
	return CHANNEL_RC_OK;
}

static UINT on_rail_local_move_size(RailClientContext* rail, const RAIL_LOCALMOVESIZE_ORDER* order)
{
	PstscClient* client = rail->custom;
	if (client && order && client->cb.localMoveSize)
		client->cb.localMoveSize(client->cb.user, order->windowId, order->isMoveSizeStart,
		                         order->moveSizeType);
	return CHANNEL_RC_OK;
}

static UINT on_rail_min_max_info(RailClientContext* rail, const RAIL_MINMAXINFO_ORDER* order)
{
	(void)rail;
	(void)order;
	return CHANNEL_RC_OK;
}

static UINT on_rail_language_bar_info(RailClientContext* rail, const RAIL_LANGBAR_INFO_ORDER* order)
{
	(void)rail;
	(void)order;
	return CHANNEL_RC_OK;
}

static char* wchar_field_to_utf8(const WCHAR* field, size_t maxChars)
{
	size_t length = 0;
	while (length < maxChars && field[length] != 0)
		length++;
	char* utf8 = length ? ConvertWCharNToUtf8Alloc(field, length, NULL) : NULL;
	return utf8 ? utf8 : strdup("");
}

static UINT on_rail_get_appid_response(RailClientContext* rail,
                                       const RAIL_GET_APPID_RESP_ORDER* order)
{
	PstscClient* client = rail->custom;
	if (!client || !order || !client->cb.windowAppId)
		return CHANNEL_RC_OK;
	char* appId = wchar_field_to_utf8(order->applicationId, ARRAYSIZE(order->applicationId));
	client->cb.windowAppId(client->cb.user, order->windowId, 0, "", appId ? appId : "");
	free(appId);
	return CHANNEL_RC_OK;
}

static UINT on_rail_get_appid_response_ex(RailClientContext* rail, const RAIL_GET_APPID_RESP_EX* order)
{
	PstscClient* client = rail->custom;
	if (!client || !order || !client->cb.windowAppId)
		return CHANNEL_RC_OK;
	char* appId = wchar_field_to_utf8(order->applicationID, ARRAYSIZE(order->applicationID));
	char* image = wchar_field_to_utf8(order->processImageName, ARRAYSIZE(order->processImageName));
	client->cb.windowAppId(client->cb.user, order->windowID, order->processId, image ? image : "",
	                       appId ? appId : "");
	free(appId);
	free(image);
	return CHANNEL_RC_OK;
}

static void rail_attach(PstscClient* client, RailClientContext* rail)
{
	client->rail = rail;
	atomic_store(&client->railStarted, false);
	rail->custom = client;
	rail->ServerExecuteResult = on_rail_exec_result;
	rail->ServerSystemParam = on_rail_server_system_param;
	rail->ServerLocalMoveSize = on_rail_local_move_size;
	rail->ServerMinMaxInfo = on_rail_min_max_info;
	rail->ServerLanguageBarInfo = on_rail_language_bar_info;
	rail->ServerGetAppIdResponse = on_rail_get_appid_response;
	rail->ServerGetAppidResponseExtended = on_rail_get_appid_response_ex;

	rdpWindowUpdate* window = client->context->update->window;
	window->WindowCreate = on_window_common;
	window->WindowUpdate = on_window_common;
	window->WindowDelete = on_window_delete;
	window->WindowIcon = on_window_icon;
	window->WindowCachedIcon = on_window_cached_icon;
	window->NotifyIconCreate = on_notify_icon;
	window->NotifyIconUpdate = on_notify_icon;
	window->NotifyIconDelete = on_notify_icon_delete;
	window->MonitoredDesktop = on_monitored_desktop;
	window->NonMonitoredDesktop = on_non_monitored_desktop;
}

/* GFX: called for every surface the server mapped to a RemoteApp window. */
static UINT on_update_window_from_surface(RdpgfxClientContext* gfx, gdiGfxSurface* surface)
{
	rdpGdi* gdi = gfx->custom;
	PstscClient* client = gdi ? client_from(gdi->context) : NULL;
	if (!client || !surface)
		return CHANNEL_RC_OK;

	if (!region16_is_empty(&surface->invalidRegion) && client->cb.windowSurfaceUpdated)
	{
		const RECTANGLE_16* r = region16_extents(&surface->invalidRegion);
		client->cb.windowSurfaceUpdated(client->cb.user, (uint32_t)surface->windowId, surface->data,
		                                surface->scanline, surface->width, surface->height,
		                                r->left, r->top, r->right - r->left, r->bottom - r->top);
	}
	region16_clear(&surface->invalidRegion);
	return CHANNEL_RC_OK;
}

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	PstscClient* client = client_from(context);
	if (client && strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
	{
		fprintf(stderr, "[pstsc] RemoteApp channel connected\n");
		rail_attach(client, (RailClientContext*)e->pInterface);
		return;
	}

	freerdp_client_OnChannelConnectedEventHandler(context, e);
	if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
	{
		fprintf(stderr, "[pstsc] graphics pipeline connected\n");
		((RdpgfxClientContext*)e->pInterface)->UpdateWindowFromSurface =
		    on_update_window_from_surface;
	}
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	PstscClient* client = client_from(context);
	if (client && strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
	{
		((RailClientContext*)e->pInterface)->custom = NULL;
		client->rail = NULL;
	}
	else
		freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

/* ---- Painting ---- */

static BOOL on_begin_paint(rdpContext* context)
{
	HGDI_WND hwnd = context->gdi->primary->hdc->hwnd;
	hwnd->invalid->null = TRUE;
	hwnd->ninvalid = 0;
	return TRUE;
}

static BOOL on_end_paint(rdpContext* context)
{
	PstscClient* client = client_from(context);
	rdpGdi* gdi = context->gdi;
	HGDI_WND hwnd = gdi->primary->hdc->hwnd;
	if (!client || !hwnd || hwnd->invalid->null)
		return TRUE;

	const GDI_RGN* region = hwnd->invalid;
	if (client->cb.frameUpdated)
		client->cb.frameUpdated(client->cb.user, gdi->primary_buffer, gdi->stride,
		                        (uint32_t)gdi->width, (uint32_t)gdi->height, region->x, region->y,
		                        region->w, region->h);

	hwnd->invalid->null = TRUE;
	hwnd->ninvalid = 0;
	return TRUE;
}

static BOOL on_desktop_resize(rdpContext* context)
{
	rdpSettings* settings = context->settings;
	return gdi_resize(context->gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
	                  freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
}

/* ---- Connection lifecycle ---- */

static BOOL on_pre_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	if (!freerdp_settings_set_uint32(context->settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH))
		return FALSE;
	if (PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected) < 0)
		return FALSE;
	if (PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected) < 0)
		return FALSE;
	return TRUE;
}

static BOOL on_post_connect(freerdp* instance)
{
	if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
		return FALSE;

	rdpUpdate* update = instance->context->update;
	update->BeginPaint = on_begin_paint;
	update->EndPaint = on_end_paint;
	update->DesktopResize = on_desktop_resize;
	return TRUE;
}

static void on_post_disconnect(freerdp* instance)
{
	rdpContext* context = instance->context;
	if (!context)
		return;
	PubSub_UnsubscribeChannelConnected(context->pubSub, on_channel_connected);
	PubSub_UnsubscribeChannelDisconnected(context->pubSub, on_channel_disconnected);
	gdi_free(instance);
}

static BOOL on_authenticate(freerdp* instance, char** username, char** password, char** domain,
                            rdp_auth_reason reason)
{
	(void)instance;
	(void)username;
	(void)domain;
	(void)reason;
	/* Credentials come from the connect dialog; there is no one to ask interactively. */
	return password && *password && **password;
}

static DWORD on_verify_certificate(freerdp* instance, const char* host, UINT16 port,
                                   const char* common_name, const char* subject,
                                   const char* issuer, const char* fingerprint, DWORD flags)
{
	(void)instance;
	(void)common_name;
	(void)subject;
	(void)issuer;
	(void)flags;
	/* First connection to this host: trust and remember it (same as /cert:tofu). */
	(void)host;
	(void)port;
	(void)fingerprint;
	fprintf(stderr, "[pstsc] trusting the server certificate on first connection\n");
	return 1;
}

static DWORD on_verify_changed_certificate(freerdp* instance, const char* host, UINT16 port,
                                           const char* common_name, const char* subject,
                                           const char* issuer, const char* fingerprint,
                                           const char* old_subject, const char* old_issuer,
                                           const char* old_fingerprint, DWORD flags)
{
	(void)instance;
	(void)common_name;
	(void)subject;
	(void)issuer;
	(void)old_subject;
	(void)old_issuer;
	(void)flags;
	(void)host;
	(void)port;
	(void)old_fingerprint;
	(void)fingerprint;
	fprintf(stderr, "[pstsc] the server certificate changed, refusing to connect\n");
	return 0;
}

static int on_logon_error_info(freerdp* instance, UINT32 data, UINT32 type)
{
	(void)type;
	PstscClient* client = client_from(instance->context);
	if (client && data == LOGON_MSG_BUMP_OPTIONS)
		notify_state(client, PSTSC_STATE_OTHER_USER_SIGNED_IN, 0, NULL);
	return 1;
}

static BOOL on_client_new(freerdp* instance, rdpContext* context)
{
	(void)context;
	instance->PreConnect = on_pre_connect;
	instance->PostConnect = on_post_connect;
	instance->PostDisconnect = on_post_disconnect;
	instance->AuthenticateEx = on_authenticate;
	instance->VerifyCertificateEx = on_verify_certificate;
	instance->VerifyChangedCertificateEx = on_verify_changed_certificate;
	instance->GetAccessToken = client_failsafe_get_access_token;
	instance->LogonErrorInfo = on_logon_error_info;
	return TRUE;
}

static void on_client_free(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
}

static void* rdp_thread(void* arg)
{
	PstscClient* client = arg;
	rdpContext* context = client->context;
	freerdp* instance = context->instance;

	notify_state(client, PSTSC_STATE_CONNECTING, 0, NULL);
	if (!freerdp_connect(instance))
	{
		const UINT32 error = freerdp_get_last_error(context);
		notify_state(client, PSTSC_STATE_FAILED, error, freerdp_get_last_error_string(error));
		freerdp_disconnect(instance);
		return NULL;
	}

	atomic_store(&client->connected, true);
	notify_state(client, PSTSC_STATE_CONNECTED, 0, NULL);

	HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
	while (!freerdp_shall_disconnect_context(context))
	{
		const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
		if (count == 0)
			break;
		if (WaitForMultipleObjects(count, handles, FALSE, INFINITE) == WAIT_FAILED)
			break;
		if (!freerdp_check_event_handles(context))
			break;
	}

	atomic_store(&client->connected, false);
	const UINT32 error = freerdp_get_last_error(context);
	freerdp_disconnect(instance);
	windows_clear(client);
	icons_clear(client);
	notify_state(client, PSTSC_STATE_DISCONNECTED, error,
	             error == FREERDP_ERROR_SUCCESS ? NULL : freerdp_get_last_error_string(error));
	return NULL;
}

/* ---- Public API ---- */

PstscClient* pstsc_client_new(PstscCallbacks callbacks)
{
	PstscClient* client = calloc(1, sizeof(PstscClient));
	if (!client)
		return NULL;
	client->cb = callbacks;
	atomic_init(&client->connected, false);
	return client;
}

static char* format_arg(const char* format, const char* value)
{
	char* arg = NULL;
	if (asprintf(&arg, format, value) < 0)
		return NULL;
	return arg;
}

bool pstsc_client_start(PstscClient* client, const PstscConnectOptions* options)
{
	if (!client || !options || client->context)
		return false;

	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry.ContextSize = sizeof(PstscContext);
	entry.ClientNew = on_client_new;
	entry.ClientFree = on_client_free;

	rdpContext* context = freerdp_client_context_new(&entry);
	if (!context)
		return false;
	((PstscContext*)context)->client = client;
	client->context = context;
	client->workAreaX = options->workAreaX;
	client->workAreaY = options->workAreaY;
	client->workAreaWidth = options->workAreaWidth;
	client->workAreaHeight = options->workAreaHeight;

	/* Reuse FreeRDP's own option parser so RemoteApp mode is configured the same way as xfreerdp. */
	char* args[16] = { 0 };
	int argc = 0;
	args[argc++] = strdup("pstsc");
	args[argc++] = format_arg("/v:%s", options->host);
	args[argc++] = format_arg("/u:%s", options->username);
	args[argc++] = format_arg("/p:%s", options->password);
	if (options->remoteApp && options->program)
	{
		char* app = NULL;
		if (options->programArguments && *options->programArguments)
		{
			if (asprintf(&app, "/app:program:%s,cmd:%s", options->program,
			             options->programArguments) < 0)
				app = NULL;
		}
		else
			app = format_arg("/app:program:%s", options->program);
		args[argc++] = app;
	}
	if (options->sharedFolder && *options->sharedFolder)
		args[argc++] = format_arg("/drive:pstsc,%s", options->sharedFolder);
	if (options->userDriveName && *options->userDriveName && options->userDrivePath &&
	    *options->userDrivePath)
	{
		char* drive = NULL;
		if (asprintf(&drive, "/drive:%s,%s", options->userDriveName, options->userDrivePath) < 0)
			drive = NULL;
		args[argc++] = drive;
	}
	char* size = NULL;
	if (asprintf(&size, "/size:%ux%u", options->desktopWidth, options->desktopHeight) < 0)
		size = NULL;
	args[argc++] = size;
	/* Play remote sound on the Mac (CoreAudio backend); without this FreeRDP uses a silent one. */
	args[argc++] = strdup("/sound:sys:mac");
	args[argc++] = strdup("/cert:tofu");
	args[argc++] = strdup("/network:auto");
	args[argc++] = strdup("+auto-reconnect");

	bool ok = true;
	for (int i = 0; i < argc; i++)
		ok = ok && args[i];
	if (ok)
		ok = freerdp_client_settings_parse_command_line(context->settings, argc, args, FALSE) >= 0;
	/* Windows 11 resets RemoteApp sessions shortly after logon without the graphics pipeline. */
	if (ok)
		ok = freerdp_settings_set_bool(context->settings, FreeRDP_SupportGraphicsPipeline, TRUE);
	/* Several Mac displays: announce each one so remote windows can move between them. */
	if (ok && options->monitors && options->monitorCount > 1)
	{
		rdpMonitor* monitors = calloc(options->monitorCount, sizeof(rdpMonitor));
		ok = monitors != NULL;
		for (uint32_t i = 0; ok && i < options->monitorCount; i++)
		{
			const PstscMonitor* m = &options->monitors[i];
			monitors[i].x = m->x;
			monitors[i].y = m->y;
			monitors[i].width = (INT32)m->width;
			monitors[i].height = (INT32)m->height;
			monitors[i].is_primary = m->primary;
			monitors[i].orig_screen = i;
		}
		ok = ok && freerdp_settings_set_monitor_def_array_sorted(context->settings, monitors,
		                                                         options->monitorCount);
		ok = ok && freerdp_settings_set_bool(context->settings, FreeRDP_UseMultimon, TRUE);
		ok = ok &&
		     freerdp_settings_set_bool(context->settings, FreeRDP_SupportMonitorLayoutPdu, TRUE);
		free(monitors);
	}
	/* Ask for process names with app-id answers and for large icons (Dock icons per program). */
	if (ok)
		ok = freerdp_settings_set_uint32(
		    context->settings, FreeRDP_RemoteAppFeatureFlags,
		    freerdp_settings_get_uint32(context->settings, FreeRDP_RemoteAppFeatureFlags) |
		        TS_RAIL_CLIENTSTATUS_GET_APPID_RESPONSE_EX_SUPPORTED |
		        TS_RAIL_CLIENTSTATUS_HIGH_DPI_ICONS_SUPPORTED);

	for (int i = 0; i < argc; i++)
	{
		if (args[i])
			memset(args[i], 0, strlen(args[i])); /* wipe the password copy */
		free(args[i]);
	}

	if (!ok)
	{
		freerdp_client_context_free(context);
		client->context = NULL;
		return false;
	}

	if (pthread_create(&client->thread, NULL, rdp_thread, client) != 0)
	{
		freerdp_client_context_free(context);
		client->context = NULL;
		return false;
	}
	client->threadStarted = true;
	return true;
}

void pstsc_client_stop(PstscClient* client)
{
	if (!client || !client->context)
		return;
	if (client->threadStarted)
	{
		freerdp_abort_connect_context(client->context);
		pthread_join(client->thread, NULL);
		client->threadStarted = false;
	}
	freerdp_client_context_free(client->context);
	client->context = NULL;
	client->rail = NULL;
}

void pstsc_client_free(PstscClient* client)
{
	if (!client)
		return;
	pstsc_client_stop(client);
	windows_clear(client);
	free(client->windows);
	icons_clear(client);
	free(client->icons);
	free(client);
}

static rdpInput* connected_input(PstscClient* client)
{
	if (!client || !client->context || !atomic_load(&client->connected))
		return NULL;
	return client->context->input;
}

static UINT16 clamp_coord(int32_t value)
{
	if (value < 0)
		return 0;
	if (value > UINT16_MAX)
		return UINT16_MAX;
	return (UINT16)value;
}

void pstsc_mouse_move(PstscClient* client, int32_t x, int32_t y)
{
	rdpInput* input = connected_input(client);
	if (input)
		(void)freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, clamp_coord(x), clamp_coord(y));
}

void pstsc_mouse_button(PstscClient* client, PstscMouseButton button, bool down, int32_t x,
                        int32_t y)
{
	rdpInput* input = connected_input(client);
	if (!input)
		return;

	UINT16 flags = down ? PTR_FLAGS_DOWN : 0;
	switch (button)
	{
		case PSTSC_MOUSE_LEFT:
			flags |= PTR_FLAGS_BUTTON1;
			break;
		case PSTSC_MOUSE_RIGHT:
			flags |= PTR_FLAGS_BUTTON2;
			break;
		case PSTSC_MOUSE_MIDDLE:
			flags |= PTR_FLAGS_BUTTON3;
			break;
	}
	(void)freerdp_input_send_mouse_event(input, flags, clamp_coord(x), clamp_coord(y));
}

void pstsc_mouse_wheel(PstscClient* client, bool horizontal, int32_t delta, int32_t x, int32_t y)
{
	rdpInput* input = connected_input(client);
	if (!input || delta == 0)
		return;

	/* Rotation is a 9-bit two's complement value; bit 8 doubles as the negative flag. */
	if (delta > 255)
		delta = 255;
	if (delta < -255)
		delta = -255;
	UINT16 flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
	flags |= (UINT16)(delta & WheelRotationMask);
	(void)freerdp_input_send_mouse_event(input, flags, clamp_coord(x), clamp_coord(y));
}

void pstsc_key(PstscClient* client, uint16_t macKeyCode, bool down)
{
	rdpInput* input = connected_input(client);
	if (!input)
		return;

	const DWORD vkcode = GetVirtualKeyCodeFromKeycode(macKeyCode, WINPR_KEYCODE_TYPE_APPLE);
	const DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkcode, WINPR_KBD_TYPE_IBM_ENHANCED);
	if ((scancode & 0xFF) == 0)
		return;
	(void)freerdp_input_send_keyboard_event_ex(input, down, FALSE, scancode);
}

void pstsc_unicode_key(PstscClient* client, uint16_t codeUnit, bool down)
{
	rdpInput* input = connected_input(client);
	if (input)
		(void)freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD_FLAGS_RELEASE,
		                                                codeUnit);
}

void pstsc_hangul_key(PstscClient* client, bool down)
{
	rdpInput* input = connected_input(client);
	if (input)
		(void)freerdp_input_send_keyboard_event_ex(input, down, FALSE, RDP_SCANCODE_HANGUL);
}

void pstsc_windows_key(PstscClient* client)
{
	rdpInput* input = connected_input(client);
	if (!input)
		return;
	(void)freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, RDP_SCANCODE_LWIN);
	(void)freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, RDP_SCANCODE_LWIN);
}

void pstsc_activate_window(PstscClient* client, uint32_t windowId, bool active)
{
	/* RAIL orders other than the start sequence are only valid once the program was launched. */
	if (!connected_input(client) || !client->rail || !atomic_load(&client->railStarted))
		return;
	const RAIL_ACTIVATE_ORDER order = { .windowId = windowId, .enabled = active };
	(void)client->rail->ClientActivate(client->rail, &order);
}

void pstsc_window_command(PstscClient* client, uint32_t windowId, uint16_t command)
{
	if (!connected_input(client) || !client->rail || !atomic_load(&client->railStarted))
		return;
	const RAIL_SYSCOMMAND_ORDER order = { .windowId = windowId, .command = command };
	(void)client->rail->ClientSystemCommand(client->rail, &order);
}

void pstsc_window_move(PstscClient* client, uint32_t windowId, int32_t left, int32_t top, int32_t right,
                       int32_t bottom)
{
	if (!connected_input(client) || !client->rail || !atomic_load(&client->railStarted))
		return;
	const RAIL_WINDOW_MOVE_ORDER order = { .windowId = windowId,
		                                   .left = (INT16)left,
		                                   .top = (INT16)top,
		                                   .right = (INT16)right,
		                                   .bottom = (INT16)bottom };
	(void)client->rail->ClientWindowMove(client->rail, &order);
}

void pstsc_notify_event(PstscClient* client, uint32_t windowId, uint32_t iconId, uint32_t message)
{
	if (!connected_input(client) || !client->rail || !atomic_load(&client->railStarted))
		return;
	const RAIL_NOTIFY_EVENT_ORDER order = { .windowId = windowId,
		                                    .notifyIconId = iconId,
		                                    .message = message };
	(void)client->rail->ClientNotifyEvent(client->rail, &order);
}

void pstsc_request_app_id(PstscClient* client, uint32_t windowId)
{
	if (!connected_input(client) || !client->rail || !atomic_load(&client->railStarted))
		return;
	const RAIL_GET_APPID_REQ_ORDER order = { .windowId = windowId };
	(void)client->rail->ClientGetAppIdRequest(client->rail, &order);
}

void pstsc_exec(PstscClient* client, const char* program, const char* arguments)
{
	if (!connected_input(client) || !client->rail || !atomic_load(&client->railStarted) || !program)
		return;
	const RAIL_EXEC_ORDER order = { .flags = 0,
		                            .RemoteApplicationProgram = program,
		                            .RemoteApplicationArguments = arguments };
	(void)client->rail->ClientExecute(client->rail, &order);
}
