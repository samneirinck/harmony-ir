import asyncio

import aiohttp
from homeassistant.exceptions import HomeAssistantError

from .const import (
    CAPTURE_DECODER_VERSION,
    CAPTURE_ERROR_HOLDOFF_SECONDS,
    CAPTURE_HTTP_TIMEOUT_SECONDS,
    CAPTURE_TIMEOUT_SECONDS,
    MAX_CAPTURE_TIMING_US,
    MAX_CARRIER_HZ,
    MAX_TIMING_COUNT,
    MAX_TRANSMIT_DURATION_US,
    MIN_CARRIER_HZ,
)


def validate_timings(timings, maximum_interval_us):
    if (
        not isinstance(timings, list)
        or not 1 <= len(timings) <= MAX_TIMING_COUNT
        or any(
            type(timing) is not int or timing == 0 or abs(timing) > maximum_interval_us
            for timing in timings
        )
        or timings[0] <= 0
    ):
        raise HomeAssistantError("Invalid Harmony IR timings")


class HarmonyClient:
    def __init__(self, session, host, port):
        self._session = session
        self._url = f"http://{host}:{port}"
        self._operation_lock = asyncio.Lock()
        self._capture_in_progress = False
        self._capture_holdoff_until = 0
        self.supports_capture = False

    @property
    def capture_active(self):
        return (
            self._capture_in_progress
            or asyncio.get_running_loop().time() < self._capture_holdoff_until
        )

    async def async_check_connection(self):
        health = await self.async_request("GET", "/health")
        if health.get("api_version") != 1 or health.get("transmitter") != "harmony-hal":
            raise HomeAssistantError("Not a compatible Harmony IR bridge")
        decoder_version = health.get("capture_decoder_version")
        self.supports_capture = (
            health.get("capture_experimental") is True
            and type(decoder_version) is int
            and decoder_version >= CAPTURE_DECODER_VERSION
        )

    async def async_request(
        self,
        method,
        path,
        payload=None,
        *,
        timeout_seconds=10,
        allow_capture_timeout=False,
    ):
        try:
            async with self._session.request(
                method,
                self._url + path,
                json=payload,
                timeout=aiohttp.ClientTimeout(total=timeout_seconds),
                allow_redirects=False,
            ) as response:
                result = await response.json()
                if (
                    allow_capture_timeout
                    and path == "/capture"
                    and response.status == 504
                    and isinstance(result, dict)
                    and result.get("capture_timeout") is True
                ):
                    return result
                if response.status != 200:
                    detail = (
                        result.get("error", "request failed")
                        if isinstance(result, dict)
                        else "request failed"
                    )
                    raise HomeAssistantError(f"Harmony IR HTTP {response.status}: {detail}")
                if not isinstance(result, dict):
                    raise HomeAssistantError("Invalid Harmony IR response")
                return result
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as error:
            detail = "Harmony IR connection/response failed."
            if path == "/transmit":
                detail += " Transmission may have occurred; do not automatically retry."
            elif path == "/capture":
                detail += " Capture may continue until its deadline; this request sends no IR."
            raise HomeAssistantError(detail) from error

    async def async_capture(self):
        if not self.supports_capture:
            raise HomeAssistantError("Update the Hub bridge before using IR capture")
        if self._operation_lock.locked() or self.capture_active:
            raise HomeAssistantError("Harmony IR is busy; wait before starting capture")
        async with self._operation_lock:
            self._capture_in_progress = True
            try:
                result = await self.async_request(
                    "POST",
                    "/capture",
                    {"timeout_s": CAPTURE_TIMEOUT_SECONDS},
                    timeout_seconds=CAPTURE_HTTP_TIMEOUT_SECONDS,
                    allow_capture_timeout=True,
                )
                self._capture_holdoff_until = 0
            except (HomeAssistantError, asyncio.CancelledError):
                self._capture_holdoff_until = (
                    asyncio.get_running_loop().time() + CAPTURE_ERROR_HOLDOFF_SECONDS
                )
                raise
            finally:
                self._capture_in_progress = False
        if result.get("capture_timeout") is True:
            return None
        decoder_version = result.get("decoder_version")
        if type(decoder_version) is not int or decoder_version < CAPTURE_DECODER_VERSION:
            raise HomeAssistantError("Hub capture decoder is outdated; update the Hub bridge")
        if result.get("decoding_error"):
            raise HomeAssistantError(f"Cannot decode IR capture: {result['decoding_error']}")
        validate_timings(result.get("timings_us"), MAX_CAPTURE_TIMING_US)
        return result

    async def async_transmit(self, frequency, timings):
        if type(frequency) is not int or not MIN_CARRIER_HZ <= frequency <= MAX_CARRIER_HZ:
            raise HomeAssistantError("Harmony IR requires a 10000–60000 Hz carrier")
        validate_timings(timings, MAX_TRANSMIT_DURATION_US)
        if sum(abs(timing) for timing in timings) > MAX_TRANSMIT_DURATION_US:
            raise HomeAssistantError("IR signal exceeds Harmony bridge timing limits")
        if self.capture_active:
            raise HomeAssistantError("IR capture may still be active; wait before sending")
        async with self._operation_lock:
            # Capture may have become uncertain while this send waited for the lock.
            if self.capture_active:
                raise HomeAssistantError("IR capture may still be active; wait before sending")
            result = await self.async_request(
                "POST", "/transmit", {"carrier_hz": frequency, "timings_us": timings}
            )
            if (
                result.get("accepted") is not True
                or result.get("cancellation_acknowledged") is not True
            ):
                raise HomeAssistantError("Harmony IR transmission/cancellation not acknowledged")
