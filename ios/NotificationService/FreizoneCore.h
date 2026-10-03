// The slice of the Go core (native/core.go) the Notification Service Extension
// calls. Every function takes a JSON request and returns a JSON result envelope
// ({"ok":..,"data":..,"error":..,"code":..}) that must be handed back to
// FreizoneFree. The full set is in the header cgo generates next to the
// archive; only these four are part of a push wake.
#ifndef FREIZONE_CORE_H
#define FREIZONE_CORE_H

extern char *CoreOpen(char *request);
extern char *CoreSetIdentity(char *request);
extern char *CoreSync(char *request);
extern char *CoreClose(char *request);
extern void FreizoneFree(char *result);

#endif
