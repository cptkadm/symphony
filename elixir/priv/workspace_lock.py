"""OS workspace ownership and inherited writer locks for Symphony.

Never unlink either inode. Metadata is diagnostic; flock grants ownership.
The owner lock serializes attempts. The activity lock prevents takeover while
an old attempt's shell/app-server still has an inherited writer descriptor.
"""
import datetime
import errno
import fcntl
import hashlib
import json
import os
import socket
import stat
import subprocess
import sys


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def open_lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError("lock must be a regular file")
    return os.fdopen(fd, "r+", encoding="utf-8")


def read_owner(lock, workspace):
    lock.seek(0)
    try:
        return json.loads(lock.read(65536))
    except (ValueError, UnicodeError):
        return {"workspace_path": workspace, "metadata_unavailable": True}


def main():
    metadata = json.loads(sys.argv[1])
    workspace = os.path.realpath(os.path.expanduser(metadata["workspace_path"]))
    if os.path.basename(workspace) == ".symphony-locks":
        raise OSError("workspace uses reserved lock directory")
    lock_dir = os.path.join(os.path.dirname(workspace), ".symphony-locks")
    os.makedirs(lock_dir, mode=0o700, exist_ok=True)
    if os.path.islink(lock_dir):
        raise OSError("lock directory must not be a symlink")
    lock_path = os.path.join(lock_dir, hashlib.sha256(os.fsencode(workspace)).hexdigest())
    with open_lock(lock_path + ".lock") as owner, open_lock(lock_path + ".activity") as activity:
        if len(sys.argv) == 3:
            # Take the writer lock BEFORE checking the attempt token. A delayed
            # launch cannot join a replacement attempt or race its acquisition.
            fcntl.flock(activity, fcntl.LOCK_SH | fcntl.LOCK_NB)
            if read_owner(owner, workspace).get("attempt_id") != metadata["attempt_id"]:
                raise OSError("workspace ownership changed before command launch")
            try:
                fcntl.flock(owner, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
            else:
                raise OSError("workspace ownership released before command launch")
            # Keep a supervisor descriptor too: runtimes may close inherited
            # descriptors on startup. Ordinary shell descendants also inherit it.
            os.set_inheritable(activity.fileno(), True)
            child = subprocess.Popen(
                ["bash", "-lc", sys.argv[2]], pass_fds=(activity.fileno(),)
            )
            status = child.wait()
            sys.exit(status if status >= 0 else 128 - status)
        try:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(activity, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            emit({"status": "locked", "owner": read_owner(owner, workspace)})
            return
        metadata.update(
            workspace_path=workspace,
            host=socket.gethostname(),
            lock_holder_pid=os.getpid(),
            acquired_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        )
        owner.seek(0)
        owner.truncate()
        json.dump(metadata, owner)
        owner.flush()
        fcntl.flock(activity, fcntl.LOCK_SH)
        emit({"status": "acquired", "owner": metadata})
        # A release line or EOF on BEAM/SSH death closes both descriptors.
        sys.stdin.buffer.readline()


try:
    main()
except (OSError, ValueError, KeyError) as error:
    emit({"status": "error", "error": str(error)})
    sys.exit(1)
