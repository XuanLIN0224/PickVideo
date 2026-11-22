"""Exercise real yt-dlp/FFmpeg merging with independent DASH start times.

Fixtures are generated locally. No account, network or user videos are required.
Run with the pinned yt-dlp package and FFmpeg/FFprobe available on this machine.
"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from yt_dlp import YoutubeDL, parse_options
from yt_dlp.postprocessor.ffmpeg import FFmpegMergerPP, FFmpegVideoRemuxerPP


class MediaSynchronizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
        cls.ffprobe = str(Path(cls.ffmpeg).with_name('ffprobe'))
        if not Path(cls.ffmpeg).is_file() or not Path(cls.ffprobe).is_file():
            raise RuntimeError('Real FFmpeg and FFprobe are required for synchronization tests')
        cls.temporary = tempfile.TemporaryDirectory(prefix='pickvideo-sync-')
        cls.root = Path(cls.temporary.name)
        # Exercise the same supported CLI option as the native application.
        cls.parameters = parse_options([
            '--ignore-config', '--no-plugin-dirs',
            '--postprocessor-args', 'Merger+ffmpeg_i1:-copyts',
        ]).ydl_opts['postprocessor_args']

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.directory = self.root / self._testMethodName
        self.directory.mkdir()

    def fixture(self, kind, offset):
        path = self.directory / f'{kind}-{offset}.mp4'
        args = [self.ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-y']
        if kind == 'video':
            args += ['-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=30:duration=2',
                     '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-bf', '0',
                     '-video_track_timescale', '16000']
        else:
            args += ['-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000:duration=3',
                     '-vn', '-c:a', 'aac', '-b:a', '128k']
        args += ['-output_ts_offset', str(offset), '-movflags', '+faststart', str(path)]
        subprocess.run(args, check=True, capture_output=True)
        if kind == 'video':
            self.assertAlmostEqual(float(self.packets(path, 'v:0')[0]['pts_time']), offset, delta=0.001)
        return path

    def packets(self, path, stream):
        result = subprocess.run([
            self.ffprobe, '-v', 'error', '-select_streams', stream,
            '-show_packets', '-show_data_hash', 'sha256',
            '-show_entries', 'packet=pts_time,dts_time,data_hash', '-of', 'json', str(path),
        ], check=True, capture_output=True, text=True)
        packets = json.loads(result.stdout)['packets']
        self.assertTrue(packets, 'fixture must contain real media packets')
        return packets

    def merge(self, video, audio, corrected=True, ext='mp4'):
        destination = self.directory / f'{"corrected" if corrected else "old"}.{ext}'
        ydl = YoutubeDL({
            'quiet': True, 'no_warnings': True, 'ffmpeg_location': self.ffmpeg,
            'postprocessor_args': self.parameters if corrected else {},
        })
        info = {
            'filepath': str(destination), 'ext': ext,
            '__files_to_merge': [str(video), str(audio)],
            'requested_formats': [
                {'vcodec': 'avc1', 'acodec': 'none', 'protocol': 'https', 'filepath': str(video)},
                {'vcodec': 'none', 'acodec': 'mp4a', 'protocol': 'https', 'filepath': str(audio)},
            ],
        }
        FFmpegMergerPP(ydl).run(info)
        return destination, ydl

    def assert_preserved(self, video, audio, output):
        source_v, source_a = self.packets(video, 'v:0'), self.packets(audio, 'a:0')
        merged_v, merged_a = self.packets(output, 'v:0'), self.packets(output, 'a:0')
        before = float(source_v[0]['pts_time']) - float(source_a[0]['pts_time'])
        after = float(merged_v[0]['pts_time']) - float(merged_a[0]['pts_time'])
        self.assertAlmostEqual(before, after, delta=0.001)
        # Validate every packet, including the end, so drift or re-encoding fails.
        for original, merged in [(source_v, merged_v), (source_a, merged_a)]:
            self.assertEqual(len(original), len(merged))
            shifts = []
            for old, new in zip(original, merged):
                self.assertEqual(old['data_hash'], new['data_hash'])
                shifts.append(float(new['pts_time']) - float(old['pts_time']))
            self.assertLessEqual(max(shifts) - min(shifts), 0.001)

    def test_old_merger_erases_a_real_start_difference(self):
        video, audio = self.fixture('video', 1.496), self.fixture('audio', 0)
        output, _ = self.merge(video, audio, corrected=False)
        before = float(self.packets(video, 'v:0')[0]['pts_time']) - float(self.packets(audio, 'a:0')[0]['pts_time'])
        after = float(self.packets(output, 'v:0')[0]['pts_time']) - float(self.packets(output, 'a:0')[0]['pts_time'])
        self.assertGreater(before, 1.4)
        self.assertAlmostEqual(before - after, 1.496, delta=0.001)

    def test_preserves_later_video_without_changing_media(self):
        video, audio = self.fixture('video', 1.496), self.fixture('audio', 0)
        output, _ = self.merge(video, audio)
        self.assert_preserved(video, audio, output)

    def test_already_aligned_tracks_remain_aligned(self):
        video, audio = self.fixture('video', 0), self.fixture('audio', 0)
        output, _ = self.merge(video, audio)
        self.assert_preserved(video, audio, output)

    def test_later_audio_keeps_its_source_timing(self):
        video, audio = self.fixture('video', 0), self.fixture('audio', 0.75)
        output, _ = self.merge(video, audio)
        self.assert_preserved(video, audio, output)

    def test_shared_nonzero_clock_preserves_relative_timing(self):
        video, audio = self.fixture('video', 2.496), self.fixture('audio', 1)
        output, _ = self.merge(video, audio)
        self.assert_preserved(video, audio, output)

    def test_mkv_preserves_relative_timing(self):
        video, audio = self.fixture('video', 1.496), self.fixture('audio', 0)
        output, _ = self.merge(video, audio, ext='mkv')
        self.assert_preserved(video, audio, output)

    def test_remux_after_merging_does_not_erase_offset(self):
        video, audio = self.fixture('video', 1.496), self.fixture('audio', 0)
        output, ydl = self.merge(video, audio, ext='mkv')
        info = {'filepath': str(output), 'ext': 'mkv'}
        _, remuxed = FFmpegVideoRemuxerPP(ydl, preferedformat='mp4').run(info)
        self.assert_preserved(video, audio, Path(remuxed['filepath']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
