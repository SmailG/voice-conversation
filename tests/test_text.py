import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
import text as t  # noqa: E402

BS_PARAGRAPH = ("Pregledao sam cijeli modul za autentifikaciju i pronašao tri problema. Prvi je da se "
                "token osvježava tek nakon što istekne, pa korisnik ponekad dobije grešku. Drugi problem "
                "je u rukovanju sesijama, jer se stare sesije nikada ne brišu iz baze. Treći je manji, "
                "ali bitan: poruke o grešci otkrivaju previše detalja o serveru.")


class CleanMarkdown(unittest.TestCase):
    def test_drops_code_tables_urls_and_paths(self):
        md = ("I finished the refactor. All **42 tests** pass.\n\n```bash\nnpm test\n```\n"
              "| a | b |\n|---|---|\nSee [docs](https://x.y) and `src/auth/session.ts` for `retryLimit`.")
        out = t.clean_markdown(md)
        self.assertEqual(out, "I finished the refactor. All 42 tests pass.\n\nSee docs and for retryLimit.")

    def test_strips_headings_and_bullets(self):
        self.assertEqual(t.clean_markdown("## Title\n- one\n* two\n1. three"), "Title\none\ntwo\nthree")


class Truncate(unittest.TestCase):
    def test_cuts_at_sentence_end(self):
        self.assertEqual(t.truncate("One two. Three four. Five six.", 22), "One two. Three four.")

    def test_short_text_untouched(self):
        self.assertEqual(t.truncate("Short.", 100), "Short.")

    def test_prepare_limit_zero_means_unlimited(self):
        long = "Sentence here. " * 300
        self.assertEqual(len(t.prepare(long, 0)), len(long.strip()))
        self.assertLessEqual(len(t.prepare(long, 2000)), 2000)


class LanguageRouting(unittest.TestCase):
    def test_bosnian_detected(self):
        for s in ["Gotovo je. Svi testovi prolaze.", "Evo, nema greške.", BS_PARAGRAPH,
                  "Dodao sam retryLimit u BrokerClient i ažurirao package.json."]:
            with self.subTest(s=s):
                self.assertTrue(t.is_bosnian(s))

    def test_english_not_misrouted(self):
        for s in ["Done. All tests pass.", "Done.", "OK",
                  "Updated the Šipovo site config; the build is green.",
                  "Fixed it — the config is in place and the service is up."]:
            with self.subTest(s=s):
                self.assertFalse(t.is_bosnian(s))


class Chunking(unittest.TestCase):
    def test_no_text_lost_and_max_respected(self):
        long_sentence = ("This single sentence is deliberately very long, it keeps going with clause "
                         "after clause, it mentions the broker, the retry logic, the session store, the "
                         "token refresh path, the database migration, and the cache warmup, and it only "
                         "ends after well over two hundred and twenty characters so it must be split.")
        for text, merge in [(BS_PARAGRAPH, 160), (BS_PARAGRAPH, 60), (long_sentence, 60), ("Done.", 60)]:
            with self.subTest(text=text[:30], merge=merge):
                chunks = t.split_chunks(text, merge)
                self.assertEqual(" ".join(chunks), " ".join(text.split()))
                self.assertLessEqual(max(map(len, chunks)), t.CHUNK_MAX)

    def test_first_chunk_is_one_sentence_for_bosnian(self):
        chunks = t.split_chunks(BS_PARAGRAPH, t.MERGE_TO["bs"])
        self.assertTrue(chunks[0].endswith("tri problema."))
        self.assertGreater(len(chunks[1]), 100)  # later sentences are merged

    def test_english_paragraph_stays_in_sentence_sized_chunks(self):
        text = ("I reviewed the whole authentication module and found three problems. The first is "
                "that the token is only refreshed after it expires. The second problem is session "
                "handling. The third is minor but important: error messages reveal too much.")
        chunks = t.split_chunks(text, t.MERGE_TO["en"])
        self.assertGreaterEqual(len(chunks), 4)
        self.assertLess(max(map(len, chunks)), 130)


class Payload(unittest.TestCase):
    def test_hook_payload(self):
        body = json.dumps({"session_id": "s1", "last_assistant_message": "Hi", "prompt": "/speak"}).encode()
        self.assertEqual(t.parse_payload(body), ("Hi", "s1", "/speak"))

    def test_empty_and_plain_and_non_object(self):
        self.assertEqual(t.parse_payload(b""), ("", None, ""))
        self.assertEqual(t.parse_payload(b"plain words"), ("plain words", None, ""))
        self.assertEqual(t.parse_payload(b"[1, 2]"), ("[1, 2]", None, ""))



class SpeakCommand(unittest.TestCase):
    def test_plain_and_plugin_qualified_forms_match(self):
        for prompt in ["/speak", "/speak again", "  /speak status", "/voice-conversation:speak",
                       "/voice-conversation:speak status", "/voice-conversation:speak\n"]:
            with self.subTest(prompt=prompt):
                self.assertTrue(t.is_speak_command(prompt))

    def test_other_prompts_do_not_match(self):
        for prompt in ["", "speak", "please /speak", "/speaker", "/voice-conversation:speakers",
                       "/voice-conversation:setup", "/other:speak-up"]:
            with self.subTest(prompt=prompt):
                self.assertFalse(t.is_speak_command(prompt))

if __name__ == "__main__":
    unittest.main()
