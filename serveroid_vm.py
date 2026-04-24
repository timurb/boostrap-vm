#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, Optional

import requests


API_BASE = os.environ.get("SERVEROID_API_BASE", "https://api.flops.ru/api/v1")
DEFAULT_TIMEOUT = float(os.environ.get("SERVEROID_TIMEOUT", "20"))
DEFAULT_POLL_INTERVAL = float(os.environ.get("SERVEROID_POLL_INTERVAL", "3"))
DEFAULT_OPERATION_TIMEOUT = float(os.environ.get("SERVEROID_OP_WAIT_TIMEOUT", "300"))


class ServeroidError(RuntimeError):
    pass


@dataclass
class Config:
    client_id: str
    api_key: str
    tenant_id: Optional[str] = None
    vm_id: Optional[str] = None
    vm_name: Optional[str] = None
    timeout: float = DEFAULT_TIMEOUT
    poll_interval: float = DEFAULT_POLL_INTERVAL
    operation_timeout: float = DEFAULT_OPERATION_TIMEOUT


class ServeroidClient:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.session = requests.Session()

    def _base_params(self) -> Dict[str, str]:
        if not self.config.client_id or not self.config.api_key:
            raise ServeroidError("SERVEROID_CLIENT_ID and SERVEROID_API_KEY are required")
        return {
            "clientId": self.config.client_id,
            "apiKey": self.config.api_key,
        }

    def _get(self, path: str, **params: Any) -> Dict[str, Any]:
        url = f"{API_BASE.rstrip('/')}/{path.lstrip('/')}"
        query = self._base_params()
        for k, v in params.items():
            if v is not None:
                query[k] = str(v)

        resp = self.session.get(url, params=query, timeout=self.config.timeout)
        resp.raise_for_status()

        try:
            data = resp.json()
        except ValueError as exc:
            raise ServeroidError(f"Non-JSON response from API: {resp.text[:300]}") from exc

        if data.get("status") != "OK":
            raise ServeroidError(json.dumps(data, ensure_ascii=False, indent=2))

        return data

    def list_vms(self) -> list[dict[str, Any]]:
        data = self._get("vm/")
        return data.get("result", [])

    def resolve_vm(self) -> tuple[str, str]:
        if self.config.vm_id and self.config.tenant_id:
            return self.config.vm_id, self.config.tenant_id

        vms = self.list_vms()

        if self.config.vm_id:
            for vm in vms:
                if str(vm.get("id")) == str(self.config.vm_id):
                    tenant_id = str(vm.get("tenantId"))
                    return str(vm["id"]), tenant_id
            raise ServeroidError(f"VM with id={self.config.vm_id} not found")

        if not self.config.vm_name:
            raise ServeroidError("Provide SERVEROID_VM_ID or SERVEROID_VM_NAME")

        matches = [vm for vm in vms if vm.get("name") == self.config.vm_name]
        if not matches:
            raise ServeroidError(f"VM with name={self.config.vm_name!r} not found")
        if len(matches) > 1:
            ids = ", ".join(str(vm.get("id")) for vm in matches)
            raise ServeroidError(
                f"More than one VM matched name={self.config.vm_name!r}: {ids}. "
                "Set SERVEROID_VM_ID explicitly."
            )

        vm = matches[0]
        return str(vm["id"]), str(vm["tenantId"])

    def vm_info(self) -> dict[str, Any]:
        vm_id, _tenant_id = self.resolve_vm()
        data = self._get(f"vm/{vm_id}/")
        return data["result"]

    def vm_state(self) -> str:
        return str(self.vm_info().get("state"))

    def operation_status(self, operation_id: str) -> dict[str, Any]:
        data = self._get(f"operation/{operation_id}/")
        return data["result"]

    def wait_operation(self, operation_id: str) -> dict[str, Any]:
        started = time.monotonic()

        while True:
            result = self.operation_status(operation_id)
            status = str(result.get("status", "UNKNOWN"))
            progress = result.get("percentage", 0)
            print(f"operation={operation_id} status={status} progress={progress}%")

            if status == "DONE":
                return result

            if status in {"FAILED", "ERROR"}:
                error_code = result.get("errorCode")
                error_message = result.get("errorMessage")
                raise ServeroidError(
                    f"Operation failed: code={error_code!r}, message={error_message!r}"
                )

            if time.monotonic() - started > self.config.operation_timeout:
                raise ServeroidError(f"Timed out waiting for operation {operation_id}")

            time.sleep(self.config.poll_interval)

    def vm_action(self, action: str, wait: bool = True) -> dict[str, Any]:
        vm_id, tenant_id = self.resolve_vm()
        data = self._get(f"vm/{vm_id}/{action}/", tenantId=tenant_id)

        operation_id = data.get("operationId")
        if not operation_id:
            raise ServeroidError(f"No operationId returned for action {action}: {data}")

        result = {
            "vm_id": vm_id,
            "tenant_id": tenant_id,
            "action": action,
            "operation_id": str(operation_id),
        }

        if wait:
            result["operation_result"] = self.wait_operation(str(operation_id))

        return result


def env(name: str, default: Optional[str] = None) -> Optional[str]:
    value = os.environ.get(name, default)
    return value if value not in {"", None} else default


def build_config(args: argparse.Namespace) -> Config:
    return Config(
        client_id=args.client_id or env("SERVEROID_CLIENT_ID", "") or "",
        api_key=args.api_key or env("SERVEROID_API_KEY", "") or "",
        tenant_id=args.tenant_id or env("SERVEROID_TENANT_ID"),
        vm_id=args.vm_id or env("SERVEROID_VM_ID"),
        vm_name=args.vm_name or env("SERVEROID_VM_NAME"),
        timeout=args.timeout,
        poll_interval=args.poll_interval,
        operation_timeout=args.operation_timeout,
    )


def print_json(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def cmd_list(client: ServeroidClient, _args: argparse.Namespace) -> None:
    rows = client.list_vms()
    simplified = []
    for vm in rows:
      simplified.append({
          "id": vm.get("id"),
          "tenantId": vm.get("tenantId"),
          "name": vm.get("name"),
          "state": vm.get("state"),
          "publicIp": (vm.get("ipAddresses") or [None])[0],
          "privateIp": vm.get("privateIpAddress"),
      })
    print_json(simplified)


def cmd_info(client: ServeroidClient, _args: argparse.Namespace) -> None:
    vm = client.vm_info()
    data = {
        "id": vm.get("id"),
        "tenantId": vm.get("tenantId"),
        "name": vm.get("name"),
        "state": vm.get("state"),
        "publicIp": (vm.get("ipAddresses") or [None])[0],
        "privateIp": vm.get("privateIpAddress"),
        "cpu": vm.get("cpu"),
        "memoryMb": vm.get("memory"),
        "diskMb": vm.get("disk"),
        "distribution": (vm.get("distribution") or {}).get("description"),
    }
    print_json(data)


def cmd_status(client: ServeroidClient, _args: argparse.Namespace) -> None:
    print(client.vm_state())


def cmd_resolve_vm(client: ServeroidClient, _args: argparse.Namespace) -> None:
    vm_id, tenant_id = client.resolve_vm()
    print_json({"vm_id": vm_id, "tenant_id": tenant_id})


def cmd_action(client: ServeroidClient, args: argparse.Namespace) -> None:
    result = client.vm_action(args.command, wait=not args.no_wait)
    print_json(result)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Small Serveroid VM wrapper")
    parser.add_argument("--client-id", default=None)
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--tenant-id", default=None)
    parser.add_argument("--vm-id", default=None)
    parser.add_argument("--vm-name", default=None)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--poll-interval", type=float, default=DEFAULT_POLL_INTERVAL)
    parser.add_argument("--operation-timeout", type=float, default=DEFAULT_OPERATION_TIMEOUT)

    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("list", "info", "status", "resolve-vm"):
        subparsers.add_parser(name)

    for name in ("start", "shutdown", "poweroff", "reboot"):
        p = subparsers.add_parser(name)
        p.add_argument("--no-wait", action="store_true")

    # алиасы под более привычные команды
    p = subparsers.add_parser("stop")
    p.add_argument("--no-wait", action="store_true")

    p = subparsers.add_parser("restart")
    p.add_argument("--no-wait", action="store_true")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "stop":
        args.command = "shutdown"
    elif args.command == "restart":
        args.command = "reboot"

    try:
        config = build_config(args)
        client = ServeroidClient(config)

        if args.command == "list":
            cmd_list(client, args)
        elif args.command == "info":
            cmd_info(client, args)
        elif args.command == "status":
            cmd_status(client, args)
        elif args.command == "resolve-vm":
            cmd_resolve_vm(client, args)
        elif args.command in {"start", "shutdown", "poweroff", "reboot"}:
            cmd_action(client, args)
        else:
            parser.error(f"Unsupported command: {args.command}")
        return 0

    except requests.HTTPError as exc:
        print(f"HTTP error: {exc}", file=sys.stderr)
        return 2
    except requests.RequestException as exc:
        print(f"Network error: {exc}", file=sys.stderr)
        return 3
    except ServeroidError as exc:
        print(f"Serveroid error: {exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
