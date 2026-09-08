#!/usr/bin/env python3
"""Run the real Demo against an owned server process and a disposable PostgreSQL DB."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--authentication-kit', type=Path, required=True)
    parser.add_argument('--simulator', required=True, help='Available iOS simulator UDID')
    parser.add_argument('--container', default='waktrainerserver-db-1')
    parser.add_argument('--database-user', default='vapor')
    args = parser.parse_args()
    server_root = Path(__file__).resolve().parents[1]
    kit = args.authentication_kit.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='authentication-e2e-'))
    print(f'Artifacts: {artifacts}', flush=True)
    # Never send fixture requests to an already running (possibly development) server.
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 8080))

    def run(command, name, cwd=server_root, **kwargs):
        with (artifacts / name).open('a') as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        if result.returncode:
            raise RuntimeError(f'{name} failed (exit {result.returncode}); inspect {artifacts / name}')

    def sql(statement):
        # The database name is deliberately fixed, never DATABASE_NAME from the development env.
        run(['docker', 'exec', '-i', args.container, 'psql', '-U', args.database_user,
             '-d', 'waktrainer_test_auth', '-v', 'ON_ERROR_STOP=1'],
            'fixture.log', input=statement, text=True)

    run(['swift', 'build'], 'server-build.log')
    binary = str(server_root / '.build/debug/WakTrainerServer')
    # configure.swift checks this environment's TEST_DATABASE_NAME before connecting.
    run([binary, 'migrate', '--env', 'testing', '--yes'], 'migrate.log')
    server_log = (artifacts / 'server.log').open('w')
    server = subprocess.Popen([binary, 'serve', '--env', 'testing', '--hostname', '127.0.0.1', '--port', '8080'],
                              cwd=server_root, stdout=server_log, stderr=subprocess.STDOUT)
    private_run = None
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('Test server exited; inspect server.log')
            try:
                with urllib.request.urlopen('http://127.0.0.1:8080/hello', timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError('Test server did not become ready')
        derived = artifacts / 'DerivedData'
        destination = f'platform=iOS Simulator,id={args.simulator}'
        run(['xcodebuild', 'build-for-testing', '-project', 'Example/AuthenticationKitDemo/AuthenticationKitDemo.xcodeproj',
             '-scheme', 'AuthenticationKitDemo', '-destination', destination,
             '-derivedDataPath', str(derived)], 'demo-build.log', cwd=kit)

        email = f'reset-{uuid.uuid4()}@example.com'
        password, token, expired = secrets.token_hex(8), secrets.token_hex(32), secrets.token_hex(32)
        request = urllib.request.Request('http://127.0.0.1:8080/auth/signup',
            data=json.dumps({'email': email, 'password': password}).encode(),
            headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request) as response:
            user_id = str(uuid.UUID(json.load(response)['user']['id']))
        rows = []
        for raw, expiration in [(token, "CURRENT_TIMESTAMP + INTERVAL '30 minutes'"),
                                (expired, "CURRENT_TIMESTAMP - INTERVAL '1 minute'")]:
            digest = hashlib.sha256(raw.encode()).hexdigest()
            rows.append(f"('{uuid.uuid4()}','{user_id}','{digest}',{expiration},CURRENT_TIMESTAMP)")
        sql('INSERT INTO password_reset_tokens (id,user_id,token_hash,expires_at,created_at) VALUES '
            + ','.join(rows) + ';')
        runs = list((derived / 'Build/Products').glob('*.xctestrun'))
        if len(runs) != 1:
            raise RuntimeError('Expected one generated xctestrun')
        with runs[0].open('rb') as source:
            configuration = plistlib.load(source)
        def inject(node):
            if isinstance(node, dict):
                if 'TestBundlePath' in node:
                    node.setdefault('EnvironmentVariables', {}).update({
                        'E2E_RESET_EMAIL': email, 'E2E_RESET_PASSWORD': password,
                        'E2E_RESET_TOKEN': token, 'E2E_EXPIRED_TOKEN': expired})
                for value in node.values():
                    inject(value)
            elif isinstance(node, list):
                for value in node:
                    inject(value)
        inject(configuration)
        private_run = runs[0].with_name('AuthenticationE2E.xctestrun')
        with private_run.open('wb') as target:
            plistlib.dump(configuration, target)
        os.chmod(private_run, 0o600)
        run(['xcodebuild', 'test-without-building', '-xctestrun', str(private_run),
             '-destination', destination, '-parallel-testing-enabled', 'NO',
             '-only-testing:AuthenticationKitDemoTests',
             '-only-testing:AuthenticationKitDemoUITests/AuthenticationKitDemoUITests',
             '-resultBundlePath', str(artifacts / 'E2E.xcresult')], 'demo-test.log', cwd=kit)
        sql('SELECT COUNT(*) AS remaining_users FROM users;')
        print('Demo HTTP and UI tests passed. Inbox delivery was not tested.', flush=True)
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        server_log.close()
        if private_run is not None:
            private_run.unlink(missing_ok=True)
        run([binary, 'migrate', '--env', 'testing', '--revert', '--yes'], 'revert.log')


if __name__ == '__main__':
    main()
