"""LLDB commands for observing our own probe's launch inputs. No swizzling or return-value changes."""
import json
from pathlib import Path
import shlex
import tempfile
import time
import lldb

_output = None
_count = 0
_breakpoints = []

def _argument(frame, index):
    triple = frame.GetThread().GetProcess().GetTarget().GetTriple()
    names = ["x0", "x1", "x2"] if "arm64" in triple else ["rdi", "rsi", "rdx"]
    return frame.FindRegister(names[index]).GetValueAsUnsigned()

def _record(frame, kind):
    global _count
    if _count >= 200: return
    _count += 1
    thread = frame.GetThread()
    frames = []
    for index in range(min(thread.GetNumFrames(), 40)):
        current = thread.GetFrameAtIndex(index)
        frames.append({"module": current.GetModule().GetFileSpec().GetFilename(),
                       "symbol": current.GetFunctionName(), "pc": hex(current.GetPC())})
    event = {"kind": kind, "timestamp": time.time(), "frames": frames}
    if _output:
        with _output.open("a", encoding="utf-8") as handle: handle.write(json.dumps(event) + "\n")
    print("ForceLegacyUI trace:", kind, "->", _output)

def on_key(frame, bp_loc, internal_dict):
    name = frame.GetFunctionName() or ""
    index = 2 if "objectForInfoDictionaryKey:" in name else (0 if "CFPreferences" in name else 1)
    pointer = _argument(frame, index)
    if not pointer: return False
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetIgnoreBreakpoints(True)
    options.SetTimeoutInMicroSeconds(100000)
    expression = f'(BOOL)[(id)0x{pointer:x} isEqualToString:@"UIDesignRequiresCompatibility"]'
    value = frame.EvaluateExpression(expression, options)
    if value.GetError().Success() and value.GetValueAsUnsigned(): _record(frame, name)
    return False

def on_sdk(frame, bp_loc, internal_dict):
    _record(frame, frame.GetFunctionName() or "SDK version query")
    return False

def start(debugger, command, result, internal_dict):
    global _output, _count
    args = shlex.split(command)
    _output = Path(args[0]).expanduser().resolve() if args else Path(tempfile.gettempdir()) / f"forcelegacyui-trace-{int(time.time())}.jsonl"
    _output.parent.mkdir(parents=True, exist_ok=True)
    _count = 0
    target = debugger.GetSelectedTarget()
    for name in ["CFBundleGetValueForInfoDictionaryKey", "-[NSBundle objectForInfoDictionaryKey:]", "CFPreferencesCopyAppValue"]:
        breakpoint = target.BreakpointCreateByName(name)
        breakpoint.SetScriptCallbackFunction(__name__ + ".on_key")
        _breakpoints.append(breakpoint.GetID())
    for name in ["dyld_get_program_sdk_version", "dyld_program_sdk_at_least"]:
        breakpoint = target.BreakpointCreateByName(name)
        breakpoint.SetScriptCallbackFunction(__name__ + ".on_sdk")
        _breakpoints.append(breakpoint.GetID())
    result.PutCString(f"Tracing to {_output}. Continue from before UIKit initialization. Entry traces show callers, not the final branch outcome.")

def stop(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    for identifier in _breakpoints: target.BreakpointDelete(identifier)
    _breakpoints.clear()
    result.PutCString("ForceLegacyUI tracing stopped.")

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.start fl-trace-start")
    debugger.HandleCommand(f"command script add -f {__name__}.stop fl-trace-stop")
