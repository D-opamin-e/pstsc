#ifndef PSTSC_RDP_H
#define PSTSC_RDP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PstscClient PstscClient;

typedef enum
{
	PSTSC_STATE_CONNECTING = 0,
	PSTSC_STATE_CONNECTED = 1,
	PSTSC_STATE_DISCONNECTED = 2,
	PSTSC_STATE_FAILED = 3,
	/* RemoteApp mode only: the first program was launched, pstsc_exec may be used now. */
	PSTSC_STATE_READY = 4,
} PstscState;

/* Merged state of one RemoteApp window. Coordinates are remote desktop pixels. */
typedef struct
{
	uint32_t windowId;
	uint32_t ownerWindowId;
	uint32_t style;
	uint32_t extendedStyle;
	uint32_t showState; /* 0 hide, 2 minimized, 3 maximized, 5 show */
	const char* title;  /* UTF-8, never NULL */
	int32_t x;
	int32_t y;
	uint32_t width;
	uint32_t height;
	/* Bounding box of the visible part, relative to the window origin.
	 * Excludes the invisible resize border Windows 10/11 puts around windows.
	 * visibleWidth == 0 means the whole window is visible. */
	int32_t visibleX;
	int32_t visibleY;
	uint32_t visibleWidth;
	uint32_t visibleHeight;
} PstscWindowInfo;

/* All callbacks run on the RDP thread. */
typedef struct
{
	void* user;
	/* errorCode: FreeRDP's last error (freerdp_get_last_error), 0 when none. */
	void (*stateChanged)(void* user, PstscState state, uint32_t errorCode, const char* message);
	void (*windowChanged)(void* user, const PstscWindowInfo* info);
	void (*windowRemoved)(void* user, uint32_t windowId);
	/* buffer is BGRX32 for the whole desktop and is only valid during the call. */
	void (*frameUpdated)(void* user, const uint8_t* buffer, uint32_t stride, uint32_t desktopWidth,
	                     uint32_t desktopHeight, int32_t x, int32_t y, int32_t width,
	                     int32_t height);
	void (*execResult)(void* user, uint16_t result, uint32_t rawResult, const char* program);
	/* Graphics pipeline (GFX): the server sends each window as its own surface, BGRX32,
	 * origin at the window's top-left. buffer is only valid during the call. */
	void (*windowSurfaceUpdated)(void* user, uint32_t windowId, const uint8_t* buffer,
	                             uint32_t stride, uint32_t surfaceWidth, uint32_t surfaceHeight,
	                             int32_t x, int32_t y, int32_t width, int32_t height);
	/* Window icon as BGRA32 (straight alpha), top-down, stride width * 4. */
	void (*windowIcon)(void* user, uint32_t windowId, uint32_t width, uint32_t height,
	                   const uint8_t* pixels);
	/* Answer to pstsc_request_app_id: which program owns the window.
	 * imageName is the full exe path (may be empty on older servers),
	 * applicationId the AppUserModelID or exe path Windows uses for taskbar grouping. */
	void (*windowAppId)(void* user, uint32_t windowId, uint32_t processId, const char* imageName,
	                    const char* applicationId);
	/* The user started (start = true) or ended dragging/resizing a window's frame on the remote
	 * side; the client should move or size it locally. moveSizeType: 1-8 resize edges
	 * (left, right, top, top-left, top-right, bottom, bottom-left, bottom-right), 9 move. */
	void (*localMoveSize)(void* user, uint32_t windowId, bool start, uint16_t moveSizeType);
	/* A notification-area (tray) icon showed a balloon tip. windowId owns the tray icon. */
	void (*trayBalloon)(void* user, uint32_t windowId, uint32_t iconId, const char* title,
	                    const char* text);
} PstscCallbacks;

/* One local display, in Windows screen coordinates: primary at (0, 0), others relative to it. */
typedef struct
{
	int32_t x;
	int32_t y;
	uint32_t width;
	uint32_t height;
	bool primary;
} PstscMonitor;

typedef struct
{
	const char* host;
	const char* username;
	const char* password;
	/* true: RemoteApp (one Mac window per remote window); false: whole remote desktop. */
	bool remoteApp;
	const char* program;          /* RemoteApp mode: first program, e.g. C:\Windows\notepad.exe */
	const char* programArguments; /* optional */
	/* Optional local folder shown to the remote PC as \\tsclient\pstsc */
	const char* sharedFolder;
	/* Optional second local folder shown in the remote Explorer as a drive (file exchange). */
	const char* userDriveName;
	const char* userDrivePath;
	uint32_t desktopWidth;
	uint32_t desktopHeight;
	/* Area remote windows may maximize into (excludes macOS menu bar and Dock). */
	int32_t workAreaX;
	int32_t workAreaY;
	uint32_t workAreaWidth;
	uint32_t workAreaHeight;
	/* Optional monitor layout (RemoteApp across several displays). With more than one monitor,
	 * desktopWidth/Height must be the size of their bounding box. */
	const PstscMonitor* monitors;
	uint32_t monitorCount;
} PstscConnectOptions;

typedef enum
{
	PSTSC_MOUSE_LEFT = 1,
	PSTSC_MOUSE_RIGHT = 2,
	PSTSC_MOUSE_MIDDLE = 3,
} PstscMouseButton;

PstscClient* pstsc_client_new(PstscCallbacks callbacks);
/* Starts the connection on a background thread. */
bool pstsc_client_start(PstscClient* client, const PstscConnectOptions* options);
/* Disconnects and waits for the RDP thread to finish. */
void pstsc_client_stop(PstscClient* client);
void pstsc_client_free(PstscClient* client);

void pstsc_mouse_move(PstscClient* client, int32_t x, int32_t y);
void pstsc_mouse_button(PstscClient* client, PstscMouseButton button, bool down, int32_t x,
                        int32_t y);
/* delta in wheel units (120 = one notch); positive scrolls up / right. */
void pstsc_mouse_wheel(PstscClient* client, bool horizontal, int32_t delta, int32_t x, int32_t y);
/* macOS virtual key code (NSEvent.keyCode). */
void pstsc_key(PstscClient* client, uint16_t macKeyCode, bool down);
void pstsc_unicode_key(PstscClient* client, uint16_t codeUnit, bool down);
/* Korean 한/영 toggle (VK_HANGUL); Mac keyboards have no such key. */
void pstsc_hangul_key(PstscClient* client, bool down);
/* Presses and releases the Windows key (opens the remote Start menu). */
void pstsc_windows_key(PstscClient* client);

void pstsc_activate_window(PstscClient* client, uint32_t windowId, bool active);
/* command: SC_MINIMIZE 0xF020, SC_MAXIMIZE 0xF030, SC_CLOSE 0xF060, SC_RESTORE 0xF120 */
void pstsc_window_command(PstscClient* client, uint32_t windowId, uint16_t command);
/* Reports a window's new frame (whole window, desktop coordinates) after a local move/resize. */
void pstsc_window_move(PstscClient* client, uint32_t windowId, int32_t left, int32_t top, int32_t right,
                       int32_t bottom);
/* Sends a mouse message to a remote tray icon, e.g. NIN_BALLOONUSERCLICK (0x0405). */
void pstsc_notify_event(PstscClient* client, uint32_t windowId, uint32_t iconId, uint32_t message);
/* Asks the server which program owns the window; answered via windowAppId. */
void pstsc_request_app_id(PstscClient* client, uint32_t windowId);
/* arguments may be NULL. */
void pstsc_exec(PstscClient* client, const char* program, const char* arguments);

#ifdef __cplusplus
}
#endif

#endif /* PSTSC_RDP_H */
