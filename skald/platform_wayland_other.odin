#+build !linux
package skald

// Stub: the native-Wayland driver preference only applies on Linux. On
// Windows and macOS SDL3 has a single native video driver, so there's no
// XWayland-vs-Wayland choice to make.
@(private)
prefer_native_wayland :: proc() {}
