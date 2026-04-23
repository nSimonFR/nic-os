#
# Voicemail assistant bot — Pipecat + Gemini Live S2S
#
# Receives inbound phone calls via Daily SIP, converses using Gemini's
# native audio-in/audio-out model, and sends a Telegram summary when
# the call ends.
#

import os
import sys
import json
import asyncio
import urllib.request

from loguru import logger

from pipecat.frames.frames import LLMRunFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    AssistantTurnStoppedMessage,
    LLMContextAggregatorPair,
    UserTurnStoppedMessage,
)
from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService
from pipecat.transports.daily.transport import DailyTransport, DailyParams

SYSTEM_PROMPT = """You are Nicolas's personal voicemail assistant. Your job is to:

1. Greet the caller warmly and let them know Nicolas is unavailable right now.
2. Ask who is calling and what the call is about.
3. If the caller provides their name and message, thank them and confirm you'll pass it along.
4. Keep the conversation under 2 minutes. Be friendly but concise.
5. If the caller asks when Nicolas will be available, say you're not sure but will make sure he gets the message.
6. Speak in the same language the caller uses (French or English).

End the call politely once you have the caller's name and message."""


async def run_bot(room_url: str, token: str, caller_id: str):
    """Run the voicemail bot in a Daily room."""
    transcript_lines: list[str] = []

    transport = DailyTransport(
        room_url,
        token,
        "Voicemail Assistant",
        params=DailyParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
        ),
    )

    llm = GeminiLiveLLMService(
        api_key=os.environ["GOOGLE_API_KEY"],
        settings=GeminiLiveLLMService.Settings(
            voice="Aoede",
            system_instruction=SYSTEM_PROMPT,
        ),
    )

    context = LLMContext(
        [
            {
                "role": "user",
                "content": "A caller just connected. Greet them.",
            },
        ],
    )

    user_aggregator, assistant_aggregator = LLMContextAggregatorPair(context)

    pipeline = Pipeline(
        [
            transport.input(),
            user_aggregator,
            llm,
            transport.output(),
            assistant_aggregator,
        ]
    )

    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
    )

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        logger.info(f"Caller connected: {caller_id}")
        await task.queue_frames([LLMRunFrame()])

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        logger.info("Caller disconnected")
        await task.cancel()

    @user_aggregator.event_handler("on_user_turn_stopped")
    async def on_user_turn_stopped(aggregator, strategy, message: UserTurnStoppedMessage):
        line = f"Caller: {message.content}"
        transcript_lines.append(line)
        logger.info(f"Transcript: {line}")

    @assistant_aggregator.event_handler("on_assistant_turn_stopped")
    async def on_assistant_turn_stopped(aggregator, message: AssistantTurnStoppedMessage):
        line = f"Assistant: {message.content}"
        transcript_lines.append(line)
        logger.info(f"Transcript: {line}")

    runner = PipelineRunner(handle_sigint=False)

    try:
        await runner.run(task)
    finally:
        await send_telegram_summary(caller_id, transcript_lines)


async def send_telegram_summary(caller_id: str, transcript_lines: list[str]):
    """Send voicemail transcript to Telegram."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        logger.warning("Telegram not configured, skipping notification")
        return

    transcript = "\n".join(transcript_lines) if transcript_lines else "(no transcript)"

    # Truncate to fit Telegram's 4096 char limit
    header = f"<b>Voicemail from {caller_id}</b>\n\n"
    max_transcript = 4096 - len(header) - 10
    if len(transcript) > max_transcript:
        transcript = transcript[:max_transcript] + "..."

    message = header + transcript

    data = json.dumps({
        "chat_id": chat_id,
        "parse_mode": "HTML",
        "text": message,
    }).encode()

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=data,
        headers={"Content-Type": "application/json"},
    )

    try:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, urllib.request.urlopen, req)
        logger.info("Telegram notification sent")
    except Exception as e:
        logger.error(f"Failed to send Telegram notification: {e}")


if __name__ == "__main__":
    # Called by server.py with: python bot.py <room_url> <token> <caller_id>
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <room_url> <token> <caller_id>")
        sys.exit(1)

    asyncio.run(run_bot(sys.argv[1], sys.argv[2], sys.argv[3]))
