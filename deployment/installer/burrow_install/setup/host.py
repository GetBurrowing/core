"""The one door to the machine: subprocesses and URLs.

Every external command the setup CLI runs goes through ``Host.run``. Tests
replace the Host with a recording fake, which is how the transcript-hygiene
test proves that no secret value ever reaches a command line: a secret may
only travel as ``input`` (the child's stdin), never in ``argv``, because a
command line is readable by every local process through ``ps``.
"""

import os
import shutil
import subprocess
import sys


class Result:
    def __init__(self, returncode, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

    @property
    def ok(self):
        return self.returncode == 0


class Host:
    """The real machine."""

    def __init__(self, environ=None):
        self.environ = dict(os.environ if environ is None else environ)
        self.platform = sys.platform

    def which(self, name):
        return shutil.which(name, path=self.environ.get("PATH"))

    def home(self):
        return os.path.expanduser("~")

    def run(self, argv, input=None, env=None, cwd=None, timeout=600):
        merged = dict(self.environ)
        if env:
            merged.update(env)
        try:
            proc = subprocess.run(
                list(argv),
                input=input,
                env=merged,
                cwd=cwd,
                timeout=timeout,
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            return Result(127, "", f"{argv[0]}: command not found")
        except subprocess.TimeoutExpired:
            return Result(124, "", f"{argv[0]}: timed out after {timeout}s")
        return Result(proc.returncode, proc.stdout, proc.stderr)

    def open_url(self, url):
        """Open ``url`` in the default browser without putting it on a command line.

        The URL can be a one-time sign-in link, so it goes to ``osascript`` on
        stdin (``open location``) rather than as ``open <url>``'s argument.
        """
        if self.platform != "darwin":
            return Result(1, "", "opening a browser is only automated on macOS")
        escaped = url.replace("\\", "\\\\").replace('"', '\\"')
        return self.run(["osascript", "-"], input=f'open location "{escaped}"\n', timeout=30)
