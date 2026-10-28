#!/usr/bin/env python3
"""Dictately 本地转写 worker（TASK-134）。

常驻进程：stdin 收 JSON 命令（每行一条），stdout 回 JSON 响应（每行一条）；
stderr 供宿主接日志。模型权重常驻内存（加载一次， Metal warmup 一次），
空闲卸载由宿主杀进程实现（重载秒级）。

命令协议：
  {"id":1,"cmd":"ping"}                                   → {"id":1,"ok":true,"result":{}}
  {"id":2,"cmd":"load","model":"/abs/model/dir"}          → {"id":2,"ok":true,"result":{"model":...}}
  {"id":3,"cmd":"transcribe","audio":"/abs/audio.wav"}    → {"id":3,"ok":true,"result":{"text":...,"duration":...}}
  {"id":4,"cmd":"shutdown"}                               → {"id":4,"ok":true,"result":{}} 后退出

依赖：mlx-audio（PyPI，Apple Silicon）。模型一律传本地目录（load_model 直通，
不经 hub 下载）。
"""
import json
import os
import sys
import tempfile
import wave

_model = None
_model_path = None
_load_model = None


def respond(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def ensure_import():
    global _load_model
    if _load_model is not None:
        return
    from mlx_audio.stt.utils import load_model
    _load_model = load_model


def write_silence(path, seconds=0.3):
    rate = 16000
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * int(rate * seconds))


def extract(result):
    """各家族 generate 返回对象或 dict，字段取 text/duration 尽力而为。"""
    text = getattr(result, "text", None)
    duration = getattr(result, "duration", None)
    if text is None and isinstance(result, dict):
        text = result.get("text")
        duration = result.get("duration", duration)
    if isinstance(duration, (int, float)):
        duration = int(round(duration))
    else:
        duration = None
    return text or "", duration


def main():
    global _model, _model_path

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except Exception as exc:  # noqa: BLE001
            respond({"id": None, "ok": False, "error": f"bad json: {exc}"})
            continue

        rid = request.get("id")
        cmd = request.get("cmd")
        try:
            if cmd == "ping":
                ensure_import()
                respond({"id": rid, "ok": True, "result": {}})

            elif cmd == "load":
                ensure_import()
                path = os.path.abspath(request["model"])
                # sentencepiece 家族守卫（bug02）：目录带 *.bpe.model 分词器
                # （SenseVoice/FunASR 家族）而 sentencepiece 缺失时，mlx-audio
                # 会静默回退成输出原始 token ID 数字串（sensevoice
                # _decode_tokens 兜底）——加载前拦截并显式报错，不让数字流
                # 冒充转写文本透传给宿主。
                if any(name.endswith(".bpe.model") for name in os.listdir(path)):
                    try:
                        import sentencepiece  # noqa: F401
                    except ImportError:
                        respond({
                            "id": rid, "ok": False,
                            "error": "runtime incomplete: sentencepiece missing "
                                     "(reinstall local runtime)"})
                        continue
                if path != _model_path:
                    _model = _load_model(path)
                    _model_path = path
                    # Metal warmup：0.3s 静音转一次，触发 GPU 内核 JIT；
                    # 静音结果本身可能为空/报错，忽略——warmup 目的已达到
                    with tempfile.TemporaryDirectory() as tmp:
                        warmup_wav = os.path.join(tmp, "warmup.wav")
                        write_silence(warmup_wav)
                        try:
                            _model.generate(warmup_wav)
                        except Exception:  # noqa: BLE001,S110
                            pass
                respond({"id": rid, "ok": True, "result": {"model": path}})

            elif cmd == "transcribe":
                ensure_import()
                if _model is None:
                    respond({"id": rid, "ok": False, "error": "no model loaded"})
                    continue
                audio = os.path.abspath(request["audio"])
                # 统一走 model.generate(路径字符串)：mlx-audio 内部按需载音频。
                # （generate_transcription(model:audio_path:) 的数组预载路径在
                #  mlx 0.31/0.32 + mlx-audio 0.5.8 组合下损坏——mx.array(array)
                #  绑定 TypeError，2026-10-11 实测；勿改回。）
                result = _model.generate(audio)
                text, duration = extract(result)
                respond({"id": rid, "ok": True, "result": {"text": text, "duration": duration}})

            elif cmd == "shutdown":
                respond({"id": rid, "ok": True, "result": {}})
                return

            else:
                respond({"id": rid, "ok": False, "error": f"unknown cmd: {cmd}"})

        except Exception as exc:  # noqa: BLE001
            respond({"id": rid, "ok": False, "error": f"{type(exc).__name__}: {exc}"})


if __name__ == "__main__":
    main()
