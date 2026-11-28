"""Checks that a background job writing to the terminal cannot scribble over herdr-tui: an interactive
shell starts a job that writes 3 s later, then runs the viewer. Compares the installed build with the one
just built. Starts keepers and prints their pids; kill those. Needs tmux and bash.
"""
import glob, json, os, subprocess, sys, tempfile, time
TOOL = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(TOOL); S = tempfile.mkdtemp(prefix="herdr-tui-bgwrite-")
OLD = os.path.expanduser("~/.local/bin/herdr-tui"); NEW = REPO + "/rust/target/release/herdr-tui"
os.makedirs(S + "/bin8", exist_ok=True)
open(S + "/bin8/omp", "w").write(f"#!/bin/sh\nexec python3 {REPO}/tool/demo-agent.py\n"); os.chmod(S + "/bin8/omp", 0o755)
def t(*a): return subprocess.run(["tmux", "-L", "bgw", *a], capture_output=True, text=True).stdout
pids = []
for name, binary in (("old", OLD), ("new", NEW)):
    home = f"{S}/home8{name}"; os.makedirs(home + "/proj", exist_ok=True)
    t("kill-server")
    t("new-session", "-d", "-x", "90", "-y", "20", "-s", "s", "-c", home + "/proj", "bash --norc --noprofile -i")
    time.sleep(0.5)
    t("send-keys", "-t", "s", "-l", "(sleep 3; echo BGJUNK-WARNING-from-a-background-job) &"); t("send-keys", "-t", "s", "Enter")
    t("send-keys", "-t", "s", "-l", f"HOME={home} PATH={S}/bin8:$PATH HERDR_TUI_THEME=light {binary}"); t("send-keys", "-t", "s", "Enter")
    end = time.time() + 10
    while time.time() < end and "Ready when you are" not in t("capture-pane", "-p", "-t", "s"): time.sleep(0.1)
    time.sleep(5)   # the background job writes while the viewer is up
    screen = t("capture-pane", "-p", "-t", "s")
    print(f"{name}: junk on the viewer's screen: {'BGJUNK' in screen}")
    t("send-keys", "-t", "s", "C-d"); time.sleep(0.8)
    t("send-keys", "-t", "s", "-l", "jobs"); t("send-keys", "-t", "s", "Enter"); time.sleep(0.4)
    jobs = [l for l in t("capture-pane", "-p", "-t", "s").splitlines() if "Stopped" in l or "Running" in l or "Done" in l]
    print(f"{name}: shell says:", jobs[-1].strip() if jobs else "(job finished)")
    for f in glob.glob(home + "/.herdr-mobile/keepers/*.json"):
        d = json.load(open(f)); pids += [d["pid"], d.get("agent_pid")]
    t("send-keys", "-t", "s", "-l", "kill %1 2>/dev/null; exit"); t("send-keys", "-t", "s", "Enter")
t("kill-server")
print("pids", *[p for p in pids if p])
