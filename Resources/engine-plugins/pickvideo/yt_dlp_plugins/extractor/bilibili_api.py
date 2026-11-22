"""Use Bilibili's video metadata API without changing playback authorization.

The upstream extractor still handles signed playback requests, formats, subtitles,
multipart videos and downloads. Only its initial HTML metadata fetch is adapted.
"""

import json
import re
from types import SimpleNamespace
from urllib.parse import urlsplit

from yt_dlp.extractor.bilibili import BiliBiliIE, BiliBiliBangumiIE
from yt_dlp.networking import Request


class _PickVideoBiliBiliIE(BiliBiliIE, plugin_name='PickVideo'):
    def _download_json(self, url, *args, **kwargs):
        result = super()._download_json(url, *args, **kwargs)
        target = urlsplit(url.url if isinstance(url, Request) else url)
        if target.hostname == 'api.bilibili.com' and target.path == '/x/web-interface/nav':
            data = result.get('data') if isinstance(result, dict) else None
            if isinstance(data, dict):
                vip = data.get('vip') if isinstance(data.get('vip'), dict) else {}
                # Only membership flags enter video metadata, never account IDs,
                # names, credentials or unrelated profile information.
                self._pickvideo_account = {
                    'logged_in': data.get('isLogin') is True,
                    'vip_status': vip.get('status') if isinstance(vip.get('status'), int) else None,
                    'vip_type': vip.get('type') if isinstance(vip.get('type'), int) else None,
                }
        return result

    def _real_extract(self, url):
        self._pickvideo_account = None
        info = super()._real_extract(url)
        if self._pickvideo_account and isinstance(info, dict):
            info['pickvideo_account'] = self._pickvideo_account
        return info

    def _download_webpage_handle(self, url, video_id, *args, **kwargs):
        if not isinstance(url, str):
            return super()._download_webpage_handle(url, video_id, *args, **kwargs)
        parsed = urlsplit(url)
        metadata = getattr(self, '_pickvideo_metadata', None)
        if (parsed.hostname == 'api.bilibili.com' and parsed.path == '/x/player/pagelist'
                and metadata and kwargs.get('query', {}).get('bvid') == metadata['bvid']):
            # The view API already returned the authoritative part list.
            return json.dumps({'code': 0, 'data': metadata['pages']}), SimpleNamespace(url=url)
        if (parsed.hostname == 'api.bilibili.com' and parsed.path == '/x/player/wbi/v2'
                and kwargs.get('fatal') is False):
            # Chapters are optional. A slow chapter request must not hold up
            # available video formats; subtitle requests retain their timeout.
            request = Request(url, extensions={'timeout': 5})
            return super()._download_webpage_handle(request, video_id, *args, **kwargs)
        match = re.fullmatch(r'/video/(?P<id>BV[0-9A-Za-z]+|av[0-9]+)/?', parsed.path)
        if parsed.hostname not in ('www.bilibili.com', 'bilibili.com') or not match:
            return super()._download_webpage_handle(url, video_id, *args, **kwargs)

        identifier = match['id']
        self._pickvideo_metadata = None
        query = {'bvid': identifier} if identifier.startswith('BV') else {'aid': identifier[2:]}
        response = self._download_json(
            Request('https://api.bilibili.com/x/web-interface/view', extensions={'timeout': 12}), video_id,
            note='Reading Bilibili video metadata API', fatal=False, query=query,
            headers={'Referer': 'https://www.bilibili.com/'})
        data = response.get('data') if isinstance(response, dict) and response.get('code') == 0 else None
        if isinstance(data, dict):
            same_video = (data.get('bvid') == identifier if identifier.startswith('BV')
                          else str(data.get('aid')) == identifier[2:])
            if same_video:
                redirect = data.get('redirect_url')
                if (isinstance(redirect, str)
                        and urlsplit(redirect).hostname in ('www.bilibili.com', 'bilibili.com')
                        and BiliBiliBangumiIE.suitable(redirect)):
                    return '', SimpleNamespace(url=redirect)
                if (data.get('bvid') and data.get('cid') and isinstance(data.get('title'), str)
                        and isinstance(data.get('pages'), list)
                        and data['pages'] and isinstance(data.get('rights') or {}, dict)
                        and not (data.get('rights') or {}).get('is_stein_gate')):
                    self._pickvideo_metadata = data
                    state = {'videoData': data, 'upData': data.get('owner') or {}}
                    # Preserve the upstream initial-state contract; no playback
                    # URLs or entitlements are invented, cached or substituted.
                    html = 'window.__INITIAL_STATE__=' + json.dumps(state, ensure_ascii=True) + ';'
                    return html, SimpleNamespace(url=url)

        self.to_screen('Video metadata API unavailable; trying the video webpage')
        return super()._download_webpage_handle(url, video_id, *args, **kwargs)
