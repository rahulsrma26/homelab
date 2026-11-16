#!/usr/bin/env python3
"""Run a command on a terminal and answer its prompts the way a person does: each answer typed
only once its prompt is on screen (input that arrives earlier is echoed by the terminal, even for
a hidden prompt). Prints everything the command printed; exits with its exit code.

    answer.py 'PROMPT REGEX' 'ANSWER' ['PROMPT REGEX' 'ANSWER' …] -- command args…
"""
import os, pty, re, select, sys, time

args = sys.argv[1:]
sep = args.index('--')
pairs = list(zip(args[:sep:2], args[1:sep:2]))
cmd = args[sep + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
seen, out, deadline = b'', b'', time.time() + 3600
while True:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk; seen += chunk
        sys.stdout.buffer.write(chunk); sys.stdout.flush()
    if pairs and re.search(pairs[0][0].encode(), seen):
        time.sleep(0.3)
        os.write(fd, pairs[0][1].encode() + b'\r')
        pairs.pop(0); seen = b''
    if time.time() > deadline:
        os.kill(pid, 9); break
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
