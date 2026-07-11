#!/usr/bin/env python3
import importlib.util
import json
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
