import unittest

from app import APP


class AppTests(unittest.TestCase):
    def test_root_returns_expected_response(self):
        response = APP.test_client().get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_data(as_text=True), "Hello, World from Flask!\n")

    def test_debugger_is_disabled(self):
        self.assertFalse(APP.debug)


if __name__ == "__main__":
    unittest.main()
