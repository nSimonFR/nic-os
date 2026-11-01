#!/usr/bin/env bash
# Silent unless the WhatsApp archive workflow drifted (then it is disabled), a
# likely false positive was archived, or the weekly volume spiked.
exec @bin@/hermes-whatsapp-audit
