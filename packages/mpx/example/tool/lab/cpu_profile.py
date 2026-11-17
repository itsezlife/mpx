"""Dart CPU samples of every isolate over one replay, by function.

    python3 tool/lab/cpu_profile.py <ws-uri> <tape> [open-route] [--out file.json]

The app must run under `flutter run --profile --dart-define=MPX_LAB=true`
(the profiler gets no samples from an app started by `am start`). The
script opens the tape's start route (`open-route`, e.g. `open` for the
stress feed), replays the tape over `lab.SET`, waits for the app's
`tape replay done` line, then reads the samples of that window from the
VM service and prints, per isolate, the top functions by self and by
inclusive share of that isolate's samples.
"""

import asyncio
import collections
import json
import subprocess
import sys
import time

import websockets


def adb(*args):
    return subprocess.run(["adb", *args], capture_output=True, text=True).stdout


def lab_set(key, value=None, name=None):
    cmd = ["shell", "am", "broadcast", "-a", "lab.SET", "--es", "key", key]
    if value is not None:
        cmd += ["--es", "value", value]
    if name is not None:
        cmd += ["--es", "name", name]
    adb(*cmd)


def wait_log(text, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if text in adb("logcat", "-d", "-s", "flutter"):
            return True
        time.sleep(1)
    return False


class Vm:
    def __init__(self, ws):
        self.ws = ws
        self.id = 0

    async def call(self, method, **params):
        self.id += 1
        await self.ws.send(json.dumps(
            {"jsonrpc": "2.0", "id": self.id, "method": method, "params": params}))
        while True:
            msg = json.loads(await self.ws.recv())
            if msg.get("id") == self.id:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]


def report(name, samples, top=25):
    functions = samples.get("functions", [])
    rows = samples.get("samples", [])
    n = len(rows)
    print(f"\n== isolate {name}: {n} samples "
          f"({samples.get('timeExtentMicros', 0) / 1e6:.1f} s, "
          f"period {samples.get('samplePeriod', 0)} us)")
    if not n:
        print("   no samples")
        return
    def fname(i):
        f = functions[i]["function"]
        owner = f.get("owner", {}).get("name") or f.get("_kind", "")
        return f"{owner}.{f.get('name', '?')}" if owner else f.get("name", "?")
    selfc = collections.Counter()
    incl = collections.Counter()
    for s in rows:
        stack = s.get("stack", [])
        if not stack:
            continue
        selfc[fname(stack[0])] += 1
        for f in set(stack):
            incl[fname(f)] += 1
    print("   self:")
    for f, c in selfc.most_common(top):
        print(f"   {100 * c / n:5.1f}%  {f}")
    print("   inclusive:")
    for f, c in incl.most_common(top):
        print(f"   {100 * c / n:5.1f}%  {f}")


async def main():
    args = sys.argv[1:]
    out = None
    if "--out" in args:
        i = args.index("--out")
        out = args[i + 1]
        del args[i:i + 2]
    if len(args) < 2:
        sys.exit(__doc__)
    uri, tape = args[0], args[1]
    route = args[2] if len(args) > 2 else None
    if not uri.endswith("/ws"):
        uri = uri.rstrip("/") + "/ws"
    async with websockets.connect(uri, max_size=None) as ws:
        vm = Vm(ws)
        info = await vm.call("getVM")
        isolates = info["isolates"] + info.get("systemIsolates", [])
        if route:
            lab_set(route)
            await asyncio.sleep(4)
        adb("logcat", "-c")
        t0 = (await vm.call("getVMTimelineMicros"))["timestamp"]
        lab_set("replay", name=tape)
        if not wait_log(f"tape replay done {tape}", 600):
            print(adb("logcat", "-d", "-s", "flutter")[-2000:])
            sys.exit("no 'tape replay done' line: refused or stuck")
        t1 = (await vm.call("getVMTimelineMicros"))["timestamp"]
        everything = {}
        info = await vm.call("getVM")
        for iso in info["isolates"]:
            try:
                s = await vm.call("getCpuSamples", isolateId=iso["id"],
                                  timeOriginMicros=t0, timeExtentMicros=t1 - t0)
            except RuntimeError as e:
                print(f"{iso['name']}: {e}")
                continue
            everything[iso["name"]] = s
            report(iso["name"], s)
        if out:
            with open(out, "w") as f:
                json.dump(everything, f)


asyncio.run(main())
