import os
import stat

import pytest

from nicos_scripts.security import sudo_totp as st


def fixed(n):
    return bytes(range(n))


def test_secret_file_is_pam_google_authenticator_format():
    text = st.secret_file("ABCDEF")
    assert text.splitlines() == ["ABCDEF", '" RATE_LIMIT 3 30', '" WINDOW_SIZE 3', '" DISALLOW_REUSE', '" TOTP_AUTH']


def test_otpauth_uri():
    assert st.otpauth("ABC", "nsimon") == "otpauth://totp/rpi5%20sudo%3Ansimon?secret=ABC&issuer=rpi5%20sudo"


def test_enroll_writes_a_private_file_and_stores_the_same_secret(tmp_path):
    stored, logs = [], []
    path = str(tmp_path / "nsimon")
    assert st.enroll(path, "nsimon", stored.append, rand=fixed, log=logs.append) == 0
    secret = open(path).read().splitlines()[0]
    assert secret == st.new_secret(fixed) and len(secret) == 32
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert stored == [st.otpauth(secret, "nsimon")]
    assert secret not in " ".join(logs)  # rootreq and the journal show the log to nsimon


def test_enroll_refuses_to_overwrite(tmp_path):
    path = tmp_path / "nsimon"
    path.write_text("OLD\n")
    assert st.enroll(str(path), "nsimon", lambda u: pytest.fail("stored"), log=lambda m: None) == 3
    assert path.read_text() == "OLD\n"


def test_enroll_leaves_nothing_when_the_vault_fails(tmp_path):
    def broken(uri):
        raise st.VaultError("down")
    with pytest.raises(st.VaultError):
        st.enroll(str(tmp_path / "nsimon"), "nsimon", broken, log=lambda m: None)
    assert os.listdir(tmp_path) == []


def test_main_defaults_to_dry_run(tmp_path):
    logs = []
    assert st.main({"SUDO_TOTP_DIR": str(tmp_path)}, log=logs.append) == 0
    assert os.listdir(tmp_path) == [] and "DRY_RUN" in logs[0]
