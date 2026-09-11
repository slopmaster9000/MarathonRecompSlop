"""Apply the SlopVR cmake string patches to app.cpp/video.cpp the way the build
does, so a broken anchor is caught without a Windows CMake run.

The SlopVR layers generate their sources by exact string replacement against
each other's output, so editing app.cpp, gpu/video.cpp, or any of the
cmake/MarathonRecompVR*.cmake modules can break a downstream anchor. That only
shows up as a configure-time FATAL_ERROR on Windows. Run this from the repo
root after touching any of them:

    python3 tools/slopvr_patch_check.py

It simulates the non-DLSS chain (the DLSS-only patches are skipped) and writes
the generated sources under the scratch directory for inspection.
"""
import pathlib, re, sys, tempfile

def unescape(cmake_string):
    out, i = [], 0
    while i < len(cmake_string):
        c = cmake_string[i]
        if c == '\\' and i + 1 < len(cmake_string):
            nxt = cmake_string[i + 1]
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(nxt, '\\' + nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)

def parse_calls(text, fn):
    """Yield (description, needle, replacement) for every fn(...) invocation."""
    calls = []
    for m in re.finditer(re.escape(fn) + r'\(', text):
        i = m.end()
        depth, start = 1, i
        while depth:
            if text[i] == '[' and text[i:i+3] == '[=[':
                j = text.index(']=]', i) + 3
                i = j
                continue
            if text[i] == '"':
                i += 1
                while text[i] != '"':
                    i += 2 if text[i] == '\\' else 1
            elif text[i] == '(':
                depth += 1
            elif text[i] == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        calls.append((m.start(), text[start:i]))
    parsed = []
    for pos, body in calls:
        args, i = [], 0
        while i < len(body):
            if body[i].isspace():
                i += 1
            elif body[i:i+3] == '[=[':
                j = body.index(']=]', i)
                args.append(('lit', body[i+3:j])); i = j + 3
            elif body[i] == '"':
                j = i + 1
                while body[j] != '"':
                    j += 2 if body[j] == '\\' else 1
                args.append(('str', unescape(body[i+1:j]))); i = j + 1
            else:
                j = i
                while j < len(body) and not body[j].isspace():
                    j += 1
                args.append(('var', body[i:j])); i = j
        parsed.append((pos, args))
    return parsed

def resolve(arg, variables):
    _, value = arg
    return re.sub(r'\$\{(_MR_VR_[A-Z0-9_]+)\}', lambda m: variables[m.group(1)], value)

def collect_vars(text):
    variables = {}
    for m in re.finditer(r'set\((_MR_VR_[A-Z0-9_]+) \[=\[(.*?)\]=\]\)', text, re.S):
        variables[m.group(1)] = m.group(2)
    return variables

def run(module, fn, sources, first_var_arg=1):
    text = pathlib.Path(module).read_text()
    variables = collect_vars(text)
    applied = 0
    # Patches guarded by if(MARATHON_RECOMP_DLSS) do not run in this build.
    skip = []
    for m in re.finditer(r'if\(MARATHON_RECOMP_DLSS\)', text):
        skip.append((m.start(), text.index('endif()', m.start())))
    for pos, args in parse_calls(text, fn):
        if len(args) != 4 or any(a <= pos <= b for a, b in skip):
            continue
        needle = resolve(args[2], variables)
        replacement = resolve(args[3], variables)
        target = args[0][1]
        name = {'_mr_vr_app': 'app', '_mr_vr_timing_app': 'app', '_mr_vr_boot_app': 'app',
                '_mr_vr_video': 'video', '_mr_vr_timing_video': 'video',
                '_mr_vr_boot_video': 'video'}.get(target)
        if name is None or name not in sources:
            continue
        if sources[name].count(needle) != 1:
            sys.exit("FAILED in %s (%s): anchor matched %d times\n---\n%s\n---"
                     % (module, resolve(args[1], variables), sources[name].count(needle), needle[:400]))
        sources[name] = sources[name].replace(needle, replacement)
        applied += 1
    print("  %-46s %2d patches OK" % (pathlib.Path(module).name, applied))
    return sources

src = {
    'app': pathlib.Path("MarathonRecomp/app.cpp").read_text(),
    'video': pathlib.Path("MarathonRecomp/gpu/video.cpp").read_text(),
}
print("simulating the non-DLSS SlopVR patch chain:")
src = run("cmake/MarathonRecompVR.cmake", "_mr_vr_replace", src)
src = run("cmake/MarathonRecompVRCaptureTimingFix.cmake", "_mr_vr_timing_replace", src)
src = run("cmake/MarathonRecompVRBootSafety.cmake", "_mr_vr_boot_replace", src)

out = pathlib.Path(tempfile.gettempdir()) / "slopvr-patch-check"
out.mkdir(exist_ok=True)
(out / "app_vr.cpp").write_text(src['app'])
(out / "video_vr.cpp").write_text(src['video'])
print("chain applied cleanly; generated sources in %s" % out)
