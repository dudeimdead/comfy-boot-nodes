"""Forge bootstrap node: on ComfyUI import, fetch boot.sh from this repo and
run it once in the background (guarded by pgrep). Exposes /forgeboot/log so
the operator can watch progress over the ComfyUI proxy."""
import subprocess
import threading
import urllib.request

LOG = "/workspace/forge_boot.log"
SCRIPT_URL = "https://raw.githubusercontent.com/dudeimdead/comfy-boot-nodes/main/boot.sh"
LOCAL_SCRIPT = "/tmp/forge_boot.sh"


def _log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(str(msg) + "\n")
    except Exception:
        pass


def _run():
    try:
        r = subprocess.run(["pgrep", "-f", "forge_boot.sh"],
                           capture_output=True)
        if r.returncode == 0:
            _log("node: boot.sh already running, skip")
            return
        urllib.request.urlretrieve(SCRIPT_URL, LOCAL_SCRIPT)
        f = open(LOG, "a")
        subprocess.Popen(["bash", LOCAL_SCRIPT], stdout=f,
                         stderr=subprocess.STDOUT, start_new_session=True)
        _log("node: boot.sh launched")
    except Exception as e:
        _log("node: launch failed: %r" % (e,))


try:
    from server import PromptServer
    from aiohttp import web

    @PromptServer.instance.routes.get("/forgeboot/log")
    async def _forgeboot_log(request):
        try:
            data = open(LOG, "rb").read()[-30000:].decode("utf-8", "replace")
        except Exception as e:
            data = "no log yet: %r" % (e,)
        return web.Response(text=data, content_type="text/plain")

    @PromptServer.instance.routes.get("/forgeboot/serverlog")
    async def _forgeboot_slog(request):
        try:
            data = open("/workspace/forge_server.log", "rb").read()[-30000:].decode("utf-8", "replace")
        except Exception as e:
            data = "no server log yet: %r" % (e,)
        return web.Response(text=data, content_type="text/plain")
except Exception:
    pass

threading.Thread(target=_run, daemon=True).start()

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
