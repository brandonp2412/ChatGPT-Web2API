from sloppa.parity_secure_api import _is_allowed_asset_url


def test_asset_proxy_accepts_known_openai_hosts():
    assert _is_allowed_asset_url("https://files.oaiusercontent.com/file-abc?sig=1")
    assert _is_allowed_asset_url("https://chatgpt.com/backend-api/files/x")
    assert _is_allowed_asset_url("https://cdn.openai.com/asset.png")
    assert _is_allowed_asset_url(
        "https://oaidalleapiprodscus.blob.core.windows.net/private/file.png?sig=x"
    )


def test_asset_proxy_rejects_http_credentials_and_unrelated_hosts():
    assert not _is_allowed_asset_url("http://files.oaiusercontent.com/file")
    assert not _is_allowed_asset_url("https://user:pass@files.oaiusercontent.com/file")
    assert not _is_allowed_asset_url("https://example.com/file")
    assert not _is_allowed_asset_url("https://oaiusercontent.com.attacker.example/file")
    assert not _is_allowed_asset_url("https://127.0.0.1/private")


def test_asset_proxy_does_not_allow_arbitrary_cloud_storage_accounts():
    assert not _is_allowed_asset_url(
        "https://attacker.blob.core.windows.net/container/file"
    )
