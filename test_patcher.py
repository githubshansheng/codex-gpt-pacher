#!/usr/bin/env python3
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("patch_codex_gpt56.py")
spec = importlib.util.spec_from_file_location("patcher", MODULE_PATH)
patcher = importlib.util.module_from_spec(spec)
assert spec.loader
sys.modules[spec.name] = patcher
spec.loader.exec_module(patcher)


class FullNoLoginModeTests(unittest.TestCase):
    def test_all_reasoning_efforts_are_enabled_by_default(self):
        args = patcher.build_parser().parse_args([])
        self.assertTrue(args.enable_ultra)
        self.assertEqual(args.default_model, "sol")
        self.assertEqual(
            [item["effort"] for item in patcher.effort_options(enable_ultra=args.enable_ultra)],
            ["low", "medium", "high", "xhigh", "max", "ultra"],
        )

    def test_legacy_enable_ultra_flag_is_accepted(self):
        args = patcher.build_parser().parse_args(["--enable-ultra"])
        self.assertTrue(args.enable_ultra)
        args = patcher.build_parser().parse_args(["--disable-ultra"])
        self.assertFalse(args.enable_ultra)

    def test_active_third_party_provider_is_made_usable_without_chatgpt_login(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "config.toml"
            config.write_text(
                'model_provider = "custom"\n'
                '[model_providers.custom]\n'
                'name = "custom"\n'
                'wire_api = "responses"\n'
                'requires_openai_auth = true\n'
                'base_url = "https://third-party.example/v1"\n',
                encoding="utf-8",
            )
            changed = patcher.enable_no_chatgpt_login_mode(config)
            text = config.read_text(encoding="utf-8")
            self.assertTrue(changed)
            self.assertIn('requires_openai_auth = false', text)
            self.assertNotIn('requires_openai_auth = true', text)

    def test_official_openai_provider_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "config.toml"
            original = (
                'model_provider = "openai"\n'
                '[model_providers.openai]\n'
                'name = "OpenAI"\n'
                'requires_openai_auth = true\n'
                'base_url = "https://api.openai.com/v1"\n'
            )
            config.write_text(original, encoding="utf-8")
            changed = patcher.enable_no_chatgpt_login_mode(config)
            self.assertFalse(changed)
            self.assertEqual(config.read_text(encoding="utf-8"), original)

    def test_default_relay_provider_is_created_for_official_config(self):
        original = (
            'model_provider = "openai"\n'
            '[model_providers.openai]\n'
            'name = "OpenAI"\n'
            'base_url = "https://api.openai.com/v1"\n'
        )
        updated, changed, provider = patcher.configure_default_provider_text(
            original,
            provider=patcher.DEFAULT_PROVIDER,
            base_url=patcher.DEFAULT_BASE_URL,
        )
        updated, no_login_changed, no_login_provider = patcher.enable_no_chatgpt_login_mode_text(updated, provider)
        self.assertTrue(changed)
        self.assertFalse(no_login_changed)
        self.assertEqual(provider, "custom")
        self.assertIsNone(no_login_provider)
        self.assertIn('model_provider = "custom"', updated)
        self.assertIn('base_url = "https://ai.heigh.vip/v1"', updated)
        self.assertIn("requires_openai_auth = false", updated)

    def test_existing_third_party_base_url_is_preserved_unless_forced(self):
        original = (
            'model_provider = "custom"\n'
            '[model_providers.custom]\n'
            'name = "custom"\n'
            'base_url = "https://third-party.example/v1"\n'
            'wire_api = "responses"\n'
            'env_key = "CODEX_CUSTOM_API_KEY"\n'
        )
        updated, changed, provider = patcher.configure_default_provider_text(
            original,
            provider=patcher.DEFAULT_PROVIDER,
            base_url=patcher.DEFAULT_BASE_URL,
        )
        self.assertFalse(changed)
        self.assertEqual(provider, "custom")
        self.assertIn('base_url = "https://third-party.example/v1"', updated)

        updated, changed, provider = patcher.configure_default_provider_text(
            original,
            provider=patcher.DEFAULT_PROVIDER,
            base_url=patcher.DEFAULT_BASE_URL,
            force_base_url=True,
        )
        self.assertTrue(changed)
        self.assertEqual(provider, "custom")
        self.assertIn('base_url = "https://ai.heigh.vip/v1"', updated)

    def test_windows_invocation_json_round_trips_chinese_paths(self):
        shell = shutil.which("powershell") or shutil.which("pwsh")
        if shell is None:
            self.skipTest("PowerShell is not available")
        script = r'''
$ErrorActionPreference = "Stop"
$path = Join-Path $env:TEMP ("codex-gpt56-json-{0}.json" -f [guid]::NewGuid().ToString("N"))
$expected = "C:\Users\郑瑞雪\Downloads\codex-gpt56-patcher\patch_codex_gpt56.py"
try {
    $invocation = [ordered]@{
        patchScript = $expected
        pythonPath = "C:\Windows\py.exe"
        pythonBaseArgs = @("-3")
        disableUltra = $false
    }
    [System.IO.File]::WriteAllText(
        $path,
        ($invocation | ConvertTo-Json -Depth 4),
        [System.Text.UTF8Encoding]::new($true)
    )
    $json = [System.IO.File]::ReadAllText(
        $path,
        [System.Text.UTF8Encoding]::new($true, $true)
    )
    $parsed = $json | ConvertFrom-Json
    if ([string]$parsed.patchScript -ne $expected) {
        throw "Chinese path did not round-trip correctly: $($parsed.patchScript)"
    }
}
finally {
    if (Test-Path -LiteralPath $path) {
        [System.IO.File]::Delete($path)
    }
}
'''
        result = subprocess.run(
            [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_windows_locate_cli_prefers_layout_cli_over_runtime_cache(self):
        old_platform_name = patcher.platform_name
        old_local_app_data = os.environ.get("LOCALAPPDATA")
        try:
            patcher.platform_name = lambda: "windows"
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                layout_cli = root / "app" / "resources" / "codex.exe"
                runtime_cli = root / "local" / "OpenAI" / "Codex" / "bin" / "999" / "codex.exe"
                layout_cli.parent.mkdir(parents=True)
                runtime_cli.parent.mkdir(parents=True)
                layout_cli.write_text("layout", encoding="utf-8")
                runtime_cli.write_text("runtime", encoding="utf-8")
                os.environ["LOCALAPPDATA"] = str(root / "local")
                layout = patcher.AppLayout("windows_dir", root / "app", root / "app" / "resources" / "app.asar", root / "app")
                self.assertEqual(patcher.locate_cli(layout), layout_cli)
        finally:
            patcher.platform_name = old_platform_name
            if old_local_app_data is None:
                os.environ.pop("LOCALAPPDATA", None)
            else:
                os.environ["LOCALAPPDATA"] = old_local_app_data


if __name__ == "__main__":
    unittest.main(verbosity=2)
