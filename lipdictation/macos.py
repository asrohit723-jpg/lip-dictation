"""macOS glue: the hold-to-talk key, pasting at the cursor, and sounds.

The key is watched with a listen-only Quartz event tap, which needs Input
Monitoring permission; pasting posts Cmd+V, which needs Accessibility. Both are
granted to the app that runs this (Terminal, iTerm, ...) in System Settings >
Privacy & Security.
"""
import subprocess
import threading
import time

import Quartz
from AppKit import NSPasteboard, NSPasteboardTypeString

KEYS = {  # name: (keycode, flag that is set while it is down)
    "right_option": (61, Quartz.kCGEventFlagMaskAlternate),
    "left_option": (58, Quartz.kCGEventFlagMaskAlternate),
    "right_command": (54, Quartz.kCGEventFlagMaskCommand),
    "right_control": (62, Quartz.kCGEventFlagMaskControl),
    "fn": (63, Quartz.kCGEventFlagMaskSecondaryFn),
}
ESCAPE = 53
V = 9


class HoldKey:
    """Calls on_down / on_up when the key is pressed and released; on_cancel on Esc."""

    def __init__(self, name, on_down, on_up, on_cancel):
        self.code, self.flag = KEYS[name]
        self.on_down, self.on_up, self.on_cancel = on_down, on_up, on_cancel
        self.down = False

    def _handle(self, proxy, etype, event, refcon):
        if etype in (Quartz.kCGEventTapDisabledByTimeout, Quartz.kCGEventTapDisabledByUserInput):
            Quartz.CGEventTapEnable(self.tap, True)
            return event
        code = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
        if etype == Quartz.kCGEventFlagsChanged and code == self.code:
            pressed = bool(Quartz.CGEventGetFlags(event) & self.flag)
            if pressed and not self.down:
                self.down = True
                self.on_down()
            elif not pressed and self.down:
                self.down = False
                self.on_up()
        elif etype == Quartz.kCGEventKeyDown and code == ESCAPE:
            self.on_cancel()
        return event

    def run(self):
        """Install the tap and run the main run loop. Does not return."""
        mask = Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged) | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
        self.tap = Quartz.CGEventTapCreate(Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
                                           Quartz.kCGEventTapOptionListenOnly, mask, self._handle, None)
        if self.tap is None:
            raise RuntimeError("Could not watch the keyboard. Allow Input Monitoring for this app in "
                               "System Settings > Privacy & Security > Input Monitoring, then restart it.")
        source = Quartz.CFMachPortCreateRunLoopSource(None, self.tap, 0)
        Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(self.tap, True)
        Quartz.CFRunLoopRun()


def _post_key(code, down, flags=0):
    ev = Quartz.CGEventCreateKeyboardEvent(None, code, down)
    Quartz.CGEventSetFlags(ev, flags)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def copy(text):
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)


def paste(text, restore_after=0.6):
    """Paste text at the cursor, then put the previous clipboard text back."""
    pb = NSPasteboard.generalPasteboard()
    previous = pb.stringForType_(NSPasteboardTypeString)
    copy(text)
    time.sleep(0.03)
    cmd = Quartz.kCGEventFlagMaskCommand
    _post_key(55, True, cmd)
    _post_key(V, True, cmd)
    _post_key(V, False, cmd)
    _post_key(55, False, 0)
    if previous is not None:
        def restore():
            time.sleep(restore_after)
            if pb.stringForType_(NSPasteboardTypeString) == text:
                copy(previous)
        threading.Thread(target=restore, daemon=True).start()


def sound(name, volume=0.3):
    subprocess.Popen(["afplay", "-v", str(volume), f"/System/Library/Sounds/{name}.aiff"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def accessibility_trusted():
    from ApplicationServices import AXIsProcessTrusted
    return bool(AXIsProcessTrusted())
