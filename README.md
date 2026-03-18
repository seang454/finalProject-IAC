### How the live output stream in installing kubespray
# Kubespray Live Output Streaming Explained

## Overview

When you run `just setup-iac` on your **local machine**, the terminal streams live output from Kubespray running on a **remote host** — line by line, in real time. This document explains exactly how that works and which components make it possible.

---

## The Full Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          YOUR LOCAL MACHINE                                     │
│                                                                                 │
│   $ just setup-iac                                                              │
│        │                                                                        │
│        ▼                                                                        │
│   ┌─────────────────────────────────────────────────────┐                      │
│   │  Justfile                                           │                      │
│   │                                                     │                      │
│   │  Step 1:                                            │                      │
│   │  ansible-playbook -i inventory.ini main-iac.yaml   │                      │
│   │        │                                            │                      │
│   │        │  Step 2 (called from within playbook):    │                      │
│   │        │  /tmp/run-kubespray.sh                    │                      │
│   └────────┼────────────────────────────────────────────┘                      │
│            │                                                                    │
└────────────┼────────────────────────────────────────────────────────────────────┘
             │
             │  SSH connection (stdout streamed line-by-line)
             │  ◄─────────────────────────────────────────────────────────────
             ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          REMOTE HOST                                            │
│                                                                                 │
│   /tmp/run-kubespray.sh                                                         │
│        │                                                                        │
│        │  Environment variables set:                                            │
│        │  ┌──────────────────────────────────────────────────┐                 │
│        │  │  PYTHONUNBUFFERED=1        → flush output now    │                 │
│        │  │  ANSIBLE_FORCE_COLOR=true  → keep colors in pipe │                 │
│        │  │  ANSIBLE_STDOUT_CALLBACK=yaml → readable format  │                 │
│        │  └──────────────────────────────────────────────────┘                 │
│        │                                                                        │
│        ▼                                                                        │
│   ansible-playbook -b -v -i <inventory> cluster.yml                            │
│        │                                                                        │
│        │  stdout + stderr                                                       │
│        ▼                                                                        │
│   2>&1  (merge stderr → stdout)                                                 │
│        │                                                                        │
│        ▼                                                                        │
│   tee /var/log/kubespray.log                                                   │
│        │                          │                                             │
│        │                          └──────────► /var/log/kubespray.log           │
│        │                                       (written to disk simultaneously) │
│        ▼                                                                        │
│   stdout  ──────────────────────────────────────────────────────────────────── │
│                                                                                 │
│   EXIT_CODE=${PIPESTATUS[0]}   ← captures ansible-playbook's real exit code    │
│                                   (NOT tee's exit code)                         │
└─────────────────────────────────────────────────────────────────────────────────┘
             │
             │  SSH streams each line back as it's produced
             ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          YOUR LOCAL TERMINAL                                    │
│                                                                                 │
│   PLAY [Deploy Kubernetes HA cluster] ****************************              │
│   TASK [kubeadm : Initialize control plane] ***********************             │
│   ok: [master-01]                                                               │
│   changed: [master-02]                                                          │
│   ...                                                                           │
│                                                                                 │
│   ✅ Kubernetes HA cluster deployed successfully!                               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Key Components Explained

### 1. `tee {{ kubespray_log }}`

```bash
ansible-playbook ... 2>&1 | tee {{ kubespray_log }}
```

`tee` is the central piece of the output strategy. It does two things simultaneously:

- **Writes** every line to the log file on disk
- **Passes** every line through to its own stdout (which flows back over SSH)

Without `tee`, you would have to choose between seeing output live *or* saving a log — not both.

---

### 2. `2>&1` — Merge stderr into stdout

```bash
... 2>&1 | tee ...
```

Ansible writes some output to **stderr** (errors, warnings) and some to **stdout** (task results). The `2>&1` redirect merges stderr into stdout *before* hitting the pipe, so `tee` captures everything — nothing is lost.

---

### 3. `PYTHONUNBUFFERED=1`

```bash
export PYTHONUNBUFFERED=1
```

Python (which Ansible is built on) normally **buffers output** when it detects it is not writing to a real TTY — it collects output in memory and flushes it in large chunks. Through a pipe, this would mean you see nothing for minutes, then a wall of text all at once.

Setting `PYTHONUNBUFFERED=1` forces Python to **flush every line immediately** as it is produced, giving you true real-time output.

---

### 4. `ANSIBLE_FORCE_COLOR=true`

```bash
export ANSIBLE_FORCE_COLOR=true
```

When Ansible detects it is writing into a pipe (not a TTY), it automatically **strips all ANSI color codes** to avoid polluting log files. This flag forces colors to be preserved so your terminal still renders them in the readable green/yellow/red format.

---

### 5. `ANSIBLE_STDOUT_CALLBACK=yaml`

```bash
export ANSIBLE_STDOUT_CALLBACK=yaml
```

Switches Ansible's output formatter from the default `minimal` style to `yaml`, which prints task results in a structured, indented, human-readable format. This makes long plays much easier to follow in the terminal.

---

### 6. `${PIPESTATUS[0]}` — Capture the real exit code

```bash
ansible-playbook ... 2>&1 | tee {{ kubespray_log }}
EXIT_CODE=${PIPESTATUS[0]}
```

This is a subtle but critical detail. In bash, when you run `cmd_a | cmd_b`:

- `$?` gives you **`cmd_b`'s** exit code (i.e., `tee`'s — which always succeeds)
- `${PIPESTATUS[0]}` gives you **`cmd_a`'s** exit code (i.e., `ansible-playbook`'s)

Without this, a failed Kubespray deployment would appear to succeed because `tee` exited `0`.

```bash
if [ $EXIT_CODE -eq 0 ]; then
  echo "✅ Kubernetes HA cluster deployed successfully!"
else
  echo "❌ Kubespray deployment FAILED (exit code: $EXIT_CODE)"
  exit $EXIT_CODE   # propagates failure back to Justfile
fi
```

---

## Important Caveat — Ansible Task Buffering

How live the output is depends on **how the runner script is invoked** in `main-iac.yaml`.

| Invocation Method | Behavior |
|---|---|
| `ansible.builtin.shell` (default) | Output is **buffered** — you see nothing until the task completes |
| `ansible.builtin.shell` + `async` / `poll: 0` | Output streams live; requires a separate log-tailing task |
| Direct SSH / `raw` module | Fully live, line by line |

If you are seeing output only at the end of the Kubespray run (rather than continuously), the task in `main-iac.yaml` that calls `/tmp/run-kubespray.sh` likely needs to be converted to an `async` task with a follow-up `tail -f` on `{{ kubespray_log }}`.

---

## Summary Table

| Component | Purpose | Without It |
|---|---|---|
| `tee` | Split output to log AND terminal | Must choose log OR live output |
| `2>&1` | Merge stderr into stdout | Errors are invisible in the stream |
| `PYTHONUNBUFFERED=1` | Flush output line by line | Output arrives in large delayed chunks |
| `ANSIBLE_FORCE_COLOR=true` | Keep ANSI colors through pipe | Plain monochrome output |
| `ANSIBLE_STDOUT_CALLBACK=yaml` | Human-readable task formatting | Compact, harder-to-read default format |
| `${PIPESTATUS[0]}` | Capture ansible-playbook's exit code | Failed deployments silently reported as success |