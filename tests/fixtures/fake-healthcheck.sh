#!/bin/bash
# A stand-in for tools/healthcheck.sh, for tests/e2e-start.sh: "the server
# answers A2S_INFO" once tests/fixtures/fake-entry.sh has said it is up.
[ -e /tmp/fake-up ]
