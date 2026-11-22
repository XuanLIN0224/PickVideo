"""Offline regression tests against the pinned upstream yt-dlp package."""

import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from yt_dlp import YoutubeDL
from yt_dlp.extractor.bilibili import BiliBiliIE
from yt_dlp.networking import Request

PLUGIN = Path(__file__).resolve().parents[1] / 'Resources/engine-plugins/pickvideo/yt_dlp_plugins/extractor/bilibili_api.py'
spec = importlib.util.spec_from_file_location('pickvideo_bilibili_test', PLUGIN)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BilibiliAPITests(unittest.TestCase):
    URL = 'https://www.bilibili.com/video/BV1xx411c7mu/?p=2&spm_id_from=333'

    def setUp(self):
        self.ydl = YoutubeDL({'quiet': True, 'no_warnings': True, 'noplaylist': True})
        self.ie = module._PickVideoBiliBiliIE(self.ydl)
        self.data = {
            'bvid': 'BV1xx411c7mu', 'aid': 106, 'cid': 101, 'title': 'fixture',
            'pages': [{'cid': 101, 'part': 'part one', 'page': 1}, {'cid': 202, 'part': 'part two', 'page': 2}],
            'owner': {'name': 'fixture uploader', 'mid': 7}, 'rights': {},
        }

    def response(self, **changes):
        return {'code': 0, 'data': {**self.data, **changes}}

    def test_metadata_does_not_fetch_the_failing_webpage(self):
        with patch.object(self.ie, '_download_json', return_value=self.response()), \
                patch.object(BiliBiliIE, '_download_webpage_handle', side_effect=AssertionError('webpage must not be requested')):
            html, handle = self.ie._download_webpage_handle(self.URL, '1xx411c7mu')
            state = self.ie._search_json(r'window\.__INITIAL_STATE__\s*=', html, 'state', 'test')
        self.assertEqual(handle.url, self.URL)
        self.assertEqual(state['videoData'], self.data)
        self.assertEqual(state['upData'], self.data['owner'])

    def test_multipart_selection_and_formats_use_upstream_logic(self):
        play = {'timelength': 10000, 'dash': {
            'audio': [{'id': 30280, 'baseUrl': 'https://media.example/audio-30280.m4s', 'mimeType': 'audio/mp4', 'codecs': 'mp4a.40.2', 'bandwidth': 128000}],
            'video': [{'id': 116, 'baseUrl': 'https://media.example/video-30080.m4s', 'mimeType': 'video/mp4', 'codecs': 'avc1.640032', 'bandwidth': 2000000, 'width': 1920, 'height': 1080, 'frameRate': '59.940', 'size': 2500000}],
        }}
        def api(url, *args, **kwargs):
            if isinstance(url, Request): url = url.url
            if url.endswith('/view'): return self.response()
            if url.endswith('/pagelist'): return {'code': 0, 'data': self.data['pages']}
            raise AssertionError(f'unexpected API: {url}')
        with patch.object(self.ie, '_download_json', side_effect=api), \
                patch.object(self.ie, '_download_playinfo', return_value=play) as playback, \
                patch.object(self.ie, '_get_chapters', return_value=None), \
                patch.object(self.ie, 'extract_subtitles', return_value=None), \
                patch.object(self.ie, 'extract_comments', return_value=None), \
                patch.object(BiliBiliIE, '_download_webpage_handle', side_effect=AssertionError('unexpected webpage')):
            info = self.ie._real_extract(self.URL)
        self.assertEqual(info['id'], 'BV1xx411c7mu_p2')
        self.assertEqual(info['uploader'], 'fixture uploader')
        self.assertEqual(playback.call_args.args[1], 202)
        self.assertEqual(len(info['formats']), 2)
        video = next(f for f in info['formats'] if f.get('height') == 1080)
        self.assertAlmostEqual(video['fps'], 59.94)
        self.assertEqual(video['filesize'], 2500000)
        self.assertEqual(video['acodec'], 'none')

    def assert_fallback(self, response, url=None):
        fallback = ('real webpage', SimpleNamespace(url=url or self.URL))
        with patch.object(self.ie, '_download_json', return_value=response), \
                patch.object(BiliBiliIE, '_download_webpage_handle', return_value=fallback) as original:
            result = self.ie._download_webpage_handle(url or self.URL, 'test', fatal=False)
        self.assertIs(result, fallback)
        self.assertEqual(original.call_args.kwargs['fatal'], False)

    def test_api_connection_failure_falls_back(self):
        self.assert_fallback(False)

    def test_permission_errors_do_not_create_metadata(self):
        for code in (-101, -403, -404, -352):
            with self.subTest(code=code): self.assert_fallback({'code': code, 'data': self.data})

    def test_mismatched_video_falls_back(self):
        self.assert_fallback(self.response(bvid='BV1otherVideo'))

    def test_incomplete_metadata_falls_back(self):
        self.assert_fallback(self.response(cid=None))
        self.assert_fallback(self.response(pages=None))

    def test_interactive_video_keeps_original_extractor(self):
        self.assert_fallback(self.response(rights={'is_stein_gate': 1}))

    def test_part_list_reuses_metadata_and_preserves_identity(self):
        self.ie._pickvideo_metadata = self.data
        with patch.object(BiliBiliIE, '_download_webpage_handle', side_effect=AssertionError('unexpected network request')):
            result = self.ie._download_json('https://api.bilibili.com/x/player/pagelist', 'test', query={'bvid': self.data['bvid']})
        self.assertEqual(result['data'], self.data['pages'])
        with patch.object(BiliBiliIE, '_download_webpage_handle', return_value=('{}', None)) as original:
            self.ie._download_json('https://api.bilibili.com/x/player/pagelist', 'test', query={'bvid': 'BV1different'})
        original.assert_called_once()

    def test_optional_chapters_have_a_short_timeout_but_subtitles_keep_the_original(self):
        url = 'https://api.bilibili.com/x/player/wbi/v2'
        with patch.object(BiliBiliIE, '_download_webpage_handle', return_value=('{}', None)) as original:
            self.ie._download_json(url, 'test', fatal=False)
        request = original.call_args.args[0]
        self.assertIsInstance(request, Request)
        self.assertEqual(request.extensions['timeout'], 5)
        with patch.object(BiliBiliIE, '_download_webpage_handle', return_value=('{}', None)) as original:
            self.ie._download_json(url, 'test', fatal=True)
        self.assertEqual(original.call_args.args[0], url)

    def test_av_links_keep_identity(self):
        url = 'https://www.bilibili.com/video/av106/?p=2'
        with patch.object(self.ie, '_download_json', return_value=self.response()) as api:
            html, handle = self.ie._download_webpage_handle(url, '106')
        self.assertEqual(api.call_args.kwargs['query'], {'aid': '106'})
        self.assertEqual(handle.url, url)
        self.assertIn('BV1xx411c7mu', html)

    def test_bangumi_redirect_is_preserved(self):
        redirect = 'https://www.bilibili.com/bangumi/play/ep21495'
        with patch.object(self.ie, '_download_json', return_value=self.response(redirect_url=redirect)):
            html, handle = self.ie._download_webpage_handle(self.URL, 'test')
        self.assertEqual((html, handle.url), ('', redirect))

    def test_other_hosts_and_non_video_requests_are_untouched(self):
        for url in ('https://bilibili.com.attacker.test/video/BV1xx411c7mu/',
                    'https://api.bilibili.com/x/player/wbi/playurl',
                    'https://www.bilibili.com/festival/event?bvid=BV1xx411c7mu',
                    Request('https://api.bilibili.com/x/web-interface/nav')):
            with self.subTest(url=str(url)), patch.object(self.ie, '_download_json', side_effect=AssertionError('unexpected API')), \
                    patch.object(BiliBiliIE, '_download_webpage_handle', return_value=('unchanged', None)):
                self.assertEqual(self.ie._download_webpage_handle(url, 'test'), ('unchanged', None))

    def test_membership_metadata_contains_only_verified_status_flags(self):
        response = {'code': 0, 'data': {'isLogin': True, 'mid': 7, 'uname': 'private fixture',
                                      'vip': {'status': 1, 'type': 2}, 'unrelated': 'must not copy'}}
        with patch.object(BiliBiliIE, '_download_json', return_value=response):
            self.ie._download_json(Request('https://api.bilibili.com/x/web-interface/nav'), 'test')
        self.assertEqual(self.ie._pickvideo_account, {'logged_in': True, 'vip_status': 1, 'vip_type': 2})

    def test_non_official_account_responses_cannot_set_membership(self):
        response = {'data': {'isLogin': True, 'vip': {'status': 1, 'type': 2}}}
        with patch.object(BiliBiliIE, '_download_json', return_value=response):
            self.ie._download_json('https://api.bilibili.com.attacker.test/x/web-interface/nav', 'test')
        self.assertIsNone(getattr(self.ie, '_pickvideo_account', None))

    def test_previous_video_membership_is_not_reused_without_a_new_check(self):
        self.ie._pickvideo_account = {'logged_in': True, 'vip_status': 1, 'vip_type': 2}
        with patch.object(BiliBiliIE, '_real_extract', return_value={'id': 'another'}):
            result = self.ie._real_extract(self.URL)
        self.assertNotIn('pickvideo_account', result)


if __name__ == '__main__':
    unittest.main(verbosity=2)
