#!/usr/bin/env python3
"""Offline command doubles for deploy.sh CLI tests; never invoke Docker/network."""
import json
import os
from pathlib import Path
import subprocess
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['TEST_ROOT'])
project = root / 'project'


def unexpected():
    with (root / 'unexpected-commands').open('a') as log:
        log.write(f'{name} {args!r}\n')
    sys.exit(97)


def output(text=''):
    print(text)
    sys.exit(0)


if name == 'curl':
    if any('registry.npmjs.org/' in arg for arg in args):
        output('{"latest":"0.1.2","next":"0.1.2","alpha":"0.1.2-alpha.1"}')
    if args[-1] in ('https://api.deepseek.com', 'http://127.0.0.1:9091/api/health'):
        output('{"status":"OK"}')
    unexpected()

if name == 'ip':
    if args == ['-4', 'route', 'get', '1.1.1.1']:
        output('1.1.1.1 via 192.168.50.1 dev eth0 src 192.168.50.10')
    unexpected()

if name == 'id' and args == ['-u']:
    output('1000')

if name == 'stat':
    # Simulate root ownership ONLY for the relocated upgrade state directory.
    if args[:2] == ['-c', '%u']:
        target = Path(args[-1]).resolve()
        output('0' if target == root / 'upgrade-state' else '1000')
    sys.exit(subprocess.run([os.environ['REAL_STAT'], *args]).returncode)

if name == 'cp':
    # Real file copies within the fixture, with an optional rollback I/O failure.
    paths = [Path(arg).resolve() for arg in args if not arg.startswith('-')]
    if not paths or not all(path.is_relative_to(root) for path in paths):
        unexpected()
    if os.environ.get('TEST_RESTORE_FAILURE') and args[-2].endswith('Dockerfile.before'):
        sys.exit(1)
    sys.exit(subprocess.run([os.environ['REAL_CP'], *args]).returncode)

if name == 'chown':
    if not Path(args[-1]).resolve().is_relative_to(root):
        unexpected()
    sys.exit(0)

if name in ('sync', 'sleep'):
    sys.exit(0)

if name == 'ss' and args == ['-ltn']:
    # Services start only after the simulated Compose up.
    print('State Recv-Q Send-Q Local Address:Port Peer Address:Port')
    if (root / 'started').exists():
        for address in ['127.0.0.1:3080', '127.0.0.1:9091']:
            print(f'LISTEN 0 4096 {address} 0.0.0.0:*')
    sys.exit(0)

if name != 'docker':
    unexpected()

if args == ['info']:
    sys.exit(0)
if args == ['version', '--format', '{{.Server.Version}}']:
    output('27.0.0')
if args[:1] == ['compose']:
    command = args[1:]
    if command[:2] == ['--profile', 'auth']:
        command = command[2:]
    if command == ['version']:
        output('Docker Compose version v2.29.0')
    if command == ['config', '--quiet']:
        sys.exit(0)
    if command == ['up', '-d']:
        (root / 'started').touch()
        sys.exit(0)
    if command == ['down']:
        (root / 'started').unlink(missing_ok=True)
        sys.exit(0)
    unexpected()
if args[:2] == ['image', 'inspect'] and args[2] == 'dsh:local':
    output('sha256:fixture-old-image')
if args[:2] in (['image', 'ls'], ['image', 'prune']):
    inventory = root / 'images.json'
    images = json.loads(inventory.read_text()) if inventory.exists() else []
    label_filter = 'label=io.github.gehennawu.dsh-nas.cleanup=dsh'
    filters = [args[i + 1] for i, arg in enumerate(args) if arg == '--filter']
    if any(item not in ('dangling=true', label_filter) for item in filters):
        unexpected()
    def selected(image):
        return (not image.get('tagged', False)
                and (label_filter not in filters or image.get('project', False)))
    if args[1] == 'ls':
        if os.environ.get('TEST_IMAGE_LIST_FAILURE'):
            sys.exit(1)
        if '--quiet' not in args or 'dangling=true' not in filters:
            unexpected()
        output('\n'.join(image['id'] for image in images if selected(image)))
    if '--force' not in args or '-a' in args or '--all' in args:
        unexpected()
    if os.environ.get('TEST_PRUNE_FAILURE'):
        sys.exit(1)
    images = [image for image in images if not (selected(image) and not image.get('referenced', False))]
    inventory.write_text(json.dumps(images))
    sys.exit(0)
if args == ['tag', 'sha256:fixture-old-image', 'dsh:local']:
    sys.exit(0)
if args[:1] == ['inspect']:
    if len(args) == 2:
        output('[{"Id":"fixture-container"}]')
    if len(args) == 4 and args[1] == '-f':
        values = {'{{.State.Running}}': 'true', '{{.Id}}': 'fixture-container',
                  '{{.Config.Image}}': 'dsh:local', '{{.State.Health.Status}}': 'healthy'}
        if args[2] == '{{.State.Health.Status}}' and os.environ.get('TEST_HEALTH_STARTING_ONCE'):
            marker = root / ('health-seen-' + args[3])
            if not marker.exists():
                marker.touch()
                output('starting')
        if args[2] == '{{.State.Status}}':
            output('running')
        if args[2] in values:
            output(values[args[2]])
    unexpected()
if args == ['ps', '--format', '{{.Names}}']:
    sys.exit(0)
if args == ['logs', 'dsh']:
    output('dsh web: http://127.0.0.1:3080/?token=fixture-not-a-secret')
if args == ['exec', 'dsh-caddy', 'wget', '-qO-', 'http://127.0.0.1:2019/config/']:
    output(os.environ['TEST_CADDY_JSON'])
if args[:2] == ['run', '--rm']:
    if '--entrypoint' in args and args[args.index('--entrypoint') + 1] == 'node':
        if '-v' in args:  # Container write probe; simulated, no real container.
            sys.exit(0)
        version = next(line.split('=', 1)[1] for line in
                       (project / 'Dockerfile').read_text().splitlines()
                       if line.startswith('ARG DSH_VERSION='))
        output(f'entrypoint=ok,mode=755,owner=0:0\nversion={version}\n'
               'client.js=original,no-marker\nindex.js=original,no-marker')
    if 'validate' in args or '--entrypoint' in args and 'sh' in args:
        sys.exit(0)
    unexpected()
unexpected()
