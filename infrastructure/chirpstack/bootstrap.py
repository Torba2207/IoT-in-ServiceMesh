#!/usr/bin/env python3
"""
ChirpStack declarative bootstrap script.

Creates / updates:
- Tenant
- Application
- Device profiles with JavaScript payload codecs
- Gateway
- Devices
- OTAA keys

Designed to be idempotent:
- existing objects are updated or skipped;
- missing objects are created;
- device keys are updated only when changed;
- DevNonce history is flushed only when keys changed.

Expected config:
  --config /config/devices.yaml

Expected env:
  CHIRPSTACK_SERVER=chirpstack.iot-system:8080
  CHIRPSTACK_API_TOKEN=<token>
  APPKEY_<DEVEUI>=<32-hex-appkey>
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, Optional, Tuple

import grpc
import yaml
from google.protobuf.descriptor import FieldDescriptor
from grpc import StatusCode

from chirpstack_api import api


# ---------------------------------------------------------------------------
# Logging / result collection
# ---------------------------------------------------------------------------

@dataclass
class BootstrapResult:
    kind: str
    name: str
    action: str
    details: str = ""


RESULTS: list[BootstrapResult] = []


def log(kind: str, name: str, action: str, details: str = "") -> None:
    RESULTS.append(BootstrapResult(kind=kind, name=name, action=action, details=details))
    suffix = f" | {details}" if details else ""
    print(f"[{kind}] {name}: {action}{suffix}", flush=True)


def fail(message: str, exit_code: int = 1) -> None:
    print(f"ERROR: {message}", file=sys.stderr, flush=True)
    sys.exit(exit_code)


# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

def normalize_eui(value: str) -> str:
    """Normalize EUI / hex string for ChirpStack: lowercase, no separators."""
    if not value:
        return value
    return (
        value.replace(":", "")
        .replace("-", "")
        .replace(" ", "")
        .strip()
        .lower()
    )


def normalize_key(value: str) -> str:
    """Normalize 128-bit key: lowercase, no separators."""
    return normalize_eui(value)


def require_hex(value: str, length: int, field_name: str) -> str:
    value = normalize_eui(value)
    if len(value) != length:
        fail(f"{field_name} must be {length} hex chars, got {len(value)}: {value}")
    try:
        int(value, 16)
    except ValueError:
        fail(f"{field_name} must be hex: {value}")
    return value


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        fail(f"Environment variable is required but not set: {name}")
    return value


def read_text_file(path_value: str, config_dir: Path) -> str:
    path = Path(path_value)
    if not path.is_absolute():
        path = config_dir / path
    if not path.exists():
        fail(f"File not found: {path}")
    return path.read_text(encoding="utf-8")


def grpc_metadata(api_token: str) -> list[tuple[str, str]]:
    return [("authorization", f"Bearer {api_token}")]


def is_not_found(exc: grpc.RpcError) -> bool:
    return exc.code() == StatusCode.NOT_FOUND


def is_already_exists(exc: grpc.RpcError) -> bool:
    return exc.code() == StatusCode.ALREADY_EXISTS


def grpc_error_message(exc: grpc.RpcError) -> str:
    try:
        return f"{exc.code().name}: {exc.details()}"
    except Exception:
        return str(exc)


# ---------------------------------------------------------------------------
# Protobuf helpers
# ---------------------------------------------------------------------------

def message_has_field(msg: Any, field_name: str) -> bool:
    return field_name in msg.DESCRIPTOR.fields_by_name


def get_field_descriptor(msg: Any, field_name: str) -> Optional[FieldDescriptor]:
    return msg.DESCRIPTOR.fields_by_name.get(field_name)


def enum_number_for_field(msg: Any, field_name: str, value: Any) -> int:
    """
    Resolve enum by field descriptor.

    Accepts:
    - int enum number
    - exact enum name, e.g. JS, EU868, LORAWAN_1_0_3
    - case-insensitive enum name
    """
    field = get_field_descriptor(msg, field_name)
    if field is None:
        raise AttributeError(f"{type(msg).__name__} has no field '{field_name}'")
    if field.type != FieldDescriptor.TYPE_ENUM:
        raise TypeError(f"{field_name} is not an enum field")

    if isinstance(value, int):
        return value

    raw = str(value).strip()
    candidates = [
        raw,
        raw.upper(),
        raw.replace("-", "_").upper(),
        raw.replace(".", "_").upper(),
    ]

    enum_type = field.enum_type
    for candidate in candidates:
        if candidate in enum_type.values_by_name:
            return enum_type.values_by_name[candidate].number

    available = ", ".join(enum_type.values_by_name.keys())
    raise ValueError(
        f"Invalid enum value '{value}' for field '{field_name}'. "
        f"Available values: {available}"
    )


def set_scalar_or_enum(msg: Any, field_name: str, value: Any, *, warn_missing: bool = False) -> bool:
    """
    Set a protobuf scalar / enum field if it exists.
    Returns True if field was set, False if missing.
    """
    field = get_field_descriptor(msg, field_name)
    if field is None:
        if warn_missing:
            print(
                f"WARNING: {type(msg).__name__} has no field '{field_name}', skipping",
                file=sys.stderr,
            )
        return False

    if value is None:
        return True

    if field.type == FieldDescriptor.TYPE_ENUM:
        setattr(msg, field_name, enum_number_for_field(msg, field_name, value))
    else:
        setattr(msg, field_name, value)

    return True


def update_map_field(msg: Any, field_name: str, values: Optional[Dict[str, Any]]) -> None:
    if not values:
        return
    if not message_has_field(msg, field_name):
        print(
            f"WARNING: {type(msg).__name__} has no map field '{field_name}', skipping",
            file=sys.stderr,
        )
        return

    target = getattr(msg, field_name)
    target.clear()
    for key, value in values.items():
        target[str(key)] = str(value)


def set_location(msg: Any, location_cfg: Optional[Dict[str, Any]]) -> None:
    if not location_cfg:
        return
    if not message_has_field(msg, "location"):
        print(
            f"WARNING: {type(msg).__name__} has no location field, skipping",
            file=sys.stderr,
        )
        return

    loc = msg.location
    for field_name in ["latitude", "longitude", "altitude"]:
        if field_name in location_cfg and message_has_field(loc, field_name):
            setattr(loc, field_name, location_cfg[field_name])

    # Some ChirpStack versions have a location.source enum.
    if "source" in location_cfg and message_has_field(loc, "source"):
        try:
            set_scalar_or_enum(loc, "source", location_cfg["source"])
        except Exception as exc:
            print(f"WARNING: could not set location.source: {exc}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def load_config(path: Path) -> Dict[str, Any]:
    if not path.exists():
        fail(f"Config file not found: {path}")

    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    if not isinstance(data, dict):
        fail("Config must be a YAML object")

    data.setdefault("tenant", {})
    data.setdefault("application", {})
    data.setdefault("gateway", {})
    data.setdefault("device_profiles", [])
    data.setdefault("devices", [])

    if not data["tenant"].get("name"):
        fail("tenant.name is required")

    if not data["application"].get("name"):
        fail("application.name is required")

    if not isinstance(data["device_profiles"], list):
        fail("device_profiles must be a list")

    if not isinstance(data["devices"], list):
        fail("devices must be a list")

    return data


# ---------------------------------------------------------------------------
# Bootstrap client
# ---------------------------------------------------------------------------

class ChirpStackBootstrap:
    def __init__(self, server: str, api_token: str, config_dir: Path, dry_run: bool = False):
        self.server = server
        self.api_token = api_token
        self.auth = grpc_metadata(api_token)
        self.config_dir = config_dir
        self.dry_run = dry_run

        self.channel = grpc.insecure_channel(server)

        self.tenant_client = api.TenantServiceStub(self.channel)
        self.application_client = api.ApplicationServiceStub(self.channel)
        self.device_profile_client = api.DeviceProfileServiceStub(self.channel)
        self.gateway_client = api.GatewayServiceStub(self.channel)
        self.device_client = api.DeviceServiceStub(self.channel)

    # -----------------------------------------------------------------------
    # Tenant
    # -----------------------------------------------------------------------

    def get_or_create_tenant(self, cfg: Dict[str, Any]) -> str:
        name = cfg["name"]
        description = cfg.get("description", "Created by chirpstack-bootstrap")
        can_have_gateways = bool(cfg.get("can_have_gateways", True))
        max_gateway_count = int(cfg.get("max_gateway_count", 0))
        max_device_count = int(cfg.get("max_device_count", 0))
        private_gateways_up = bool(cfg.get("private_gateways_up", False))
        private_gateways_down = bool(cfg.get("private_gateways_down", False))
        tags = cfg.get("tags", {})

        existing = self.find_tenant_by_name(name)
        if existing:
            tenant_id = existing.id
            tenant = self.tenant_client.Get(
                api.GetTenantRequest(id=tenant_id),
                metadata=self.auth,
            ).tenant

            changed = False
            if tenant.description != description:
                tenant.description = description
                changed = True
            if tenant.can_have_gateways != can_have_gateways:
                tenant.can_have_gateways = can_have_gateways
                changed = True
            if tenant.max_gateway_count != max_gateway_count:
                tenant.max_gateway_count = max_gateway_count
                changed = True
            if tenant.max_device_count != max_device_count:
                tenant.max_device_count = max_device_count
                changed = True
            if tenant.private_gateways_up != private_gateways_up:
                tenant.private_gateways_up = private_gateways_up
                changed = True
            if tenant.private_gateways_down != private_gateways_down:
                tenant.private_gateways_down = private_gateways_down
                changed = True

            desired_tags = {str(k): str(v) for k, v in tags.items()}
            current_tags = dict(tenant.tags)
            if desired_tags and current_tags != desired_tags:
                tenant.tags.clear()
                tenant.tags.update(desired_tags)
                changed = True

            if changed:
                if not self.dry_run:
                    req = api.UpdateTenantRequest()
                    req.tenant.CopyFrom(tenant)
                    self.tenant_client.Update(req, metadata=self.auth)
                log("Tenant", name, "updated", tenant_id)
            else:
                log("Tenant", name, "exists", tenant_id)

            return tenant_id

        tenant = api.Tenant()
        tenant.name = name
        tenant.description = description
        tenant.can_have_gateways = can_have_gateways
        tenant.max_gateway_count = max_gateway_count
        tenant.max_device_count = max_device_count
        tenant.private_gateways_up = private_gateways_up
        tenant.private_gateways_down = private_gateways_down
        update_map_field(tenant, "tags", tags)

        if self.dry_run:
            log("Tenant", name, "would-create")
            return "dry-run-tenant-id"

        req = api.CreateTenantRequest()
        req.tenant.CopyFrom(tenant)
        resp = self.tenant_client.Create(req, metadata=self.auth)

        log("Tenant", name, "created", resp.id)
        return resp.id

    def find_tenant_by_name(self, name: str) -> Optional[Any]:
        req = api.ListTenantsRequest(limit=100, offset=0, search=name)
        resp = self.tenant_client.List(req, metadata=self.auth)

        for item in resp.result:
            if item.name == name:
                return item
        return None

    # -----------------------------------------------------------------------
    # Application
    # -----------------------------------------------------------------------

    def get_or_create_application(self, tenant_id: str, cfg: Dict[str, Any]) -> str:
        name = cfg["name"]
        description = cfg.get("description", "Created by chirpstack-bootstrap")
        tags = cfg.get("tags", {})

        existing = self.find_application_by_name(tenant_id, name)
        if existing:
            app_id = existing.id
            app = self.application_client.Get(
                api.GetApplicationRequest(id=app_id),
                metadata=self.auth,
            ).application

            changed = False
            if app.description != description:
                app.description = description
                changed = True

            desired_tags = {str(k): str(v) for k, v in tags.items()}
            current_tags = dict(app.tags)
            if desired_tags and current_tags != desired_tags:
                app.tags.clear()
                app.tags.update(desired_tags)
                changed = True

            if changed:
                if not self.dry_run:
                    req = api.UpdateApplicationRequest()
                    req.application.CopyFrom(app)
                    self.application_client.Update(req, metadata=self.auth)
                log("Application", name, "updated", app_id)
            else:
                log("Application", name, "exists", app_id)

            return app_id

        app = api.Application()
        app.name = name
        app.description = description
        app.tenant_id = tenant_id
        update_map_field(app, "tags", tags)

        if self.dry_run:
            log("Application", name, "would-create")
            return "dry-run-application-id"

        req = api.CreateApplicationRequest()
        req.application.CopyFrom(app)
        resp = self.application_client.Create(req, metadata=self.auth)

        log("Application", name, "created", resp.id)
        return resp.id

    def find_application_by_name(self, tenant_id: str, name: str) -> Optional[Any]:
        req = api.ListApplicationsRequest(limit=100, offset=0, tenant_id=tenant_id, search=name)
        resp = self.application_client.List(req, metadata=self.auth)

        for item in resp.result:
            if item.name == name:
                return item
        return None

    # -----------------------------------------------------------------------
    # Device profile
    # -----------------------------------------------------------------------

    def get_or_create_device_profiles(
        self,
        tenant_id: str,
        profiles_cfg: Iterable[Dict[str, Any]],
    ) -> Dict[str, str]:
        profile_ids: Dict[str, str] = {}

        for cfg in profiles_cfg:
            name = cfg.get("name")
            if not name:
                fail("Every device profile must have name")

            profile_id = self.get_or_create_device_profile(tenant_id, cfg)
            profile_ids[name] = profile_id

        return profile_ids

    def get_or_create_device_profile(self, tenant_id: str, cfg: Dict[str, Any]) -> str:
        name = cfg["name"]
        existing = self.find_device_profile_by_name(tenant_id, name)

        if existing:
            profile_id = existing.id
            profile = self.device_profile_client.Get(
                api.GetDeviceProfileRequest(id=profile_id),
                metadata=self.auth,
            ).device_profile

            changed = self.apply_device_profile_config(profile, tenant_id, cfg)

            if changed:
                if not self.dry_run:
                    req = api.UpdateDeviceProfileRequest()
                    req.device_profile.CopyFrom(profile)
                    self.device_profile_client.Update(req, metadata=self.auth)
                log("DeviceProfile", name, "updated", profile_id)
            else:
                log("DeviceProfile", name, "exists", profile_id)

            return profile_id

        profile = api.DeviceProfile()
        self.apply_device_profile_config(profile, tenant_id, cfg, force=True)

        if self.dry_run:
            log("DeviceProfile", name, "would-create")
            return f"dry-run-device-profile-id-{name}"

        req = api.CreateDeviceProfileRequest()
        req.device_profile.CopyFrom(profile)
        resp = self.device_profile_client.Create(req, metadata=self.auth)

        log("DeviceProfile", name, "created", resp.id)
        return resp.id

    def find_device_profile_by_name(self, tenant_id: str, name: str) -> Optional[Any]:
        req = api.ListDeviceProfilesRequest(limit=100, offset=0, tenant_id=tenant_id, search=name)
        resp = self.device_profile_client.List(req, metadata=self.auth)

        for item in resp.result:
            if item.name == name:
                return item
        return None

    def apply_device_profile_config(
        self,
        profile: Any,
        tenant_id: str,
        cfg: Dict[str, Any],
        force: bool = False,
    ) -> bool:
        """
        Apply config to a DeviceProfile protobuf.
        Returns True if values changed.
        """
        before = profile.SerializeToString()

        profile.tenant_id = tenant_id
        profile.name = cfg["name"]
        profile.description = cfg.get("description", "Created by chirpstack-bootstrap")

        # Main LoRaWAN settings.
        set_scalar_or_enum(profile, "region", cfg.get("region", "EU868"), warn_missing=True)
        set_scalar_or_enum(profile, "mac_version", cfg.get("mac_version", "LORAWAN_1_0_3"), warn_missing=True)
        set_scalar_or_enum(
            profile,
            "reg_params_revision",
            cfg.get("reg_params_revision", "RP002_1_0_3"),
            warn_missing=True,
        )

        # Common settings.
        set_scalar_or_enum(profile, "supports_otaa", bool(cfg.get("supports_otaa", True)))
        set_scalar_or_enum(profile, "supports_class_b", bool(cfg.get("supports_class_b", False)))
        set_scalar_or_enum(profile, "supports_class_c", bool(cfg.get("supports_class_c", False)))
        set_scalar_or_enum(profile, "flush_queue_on_activate", bool(cfg.get("flush_queue_on_activate", True)))

        if "uplink_interval" in cfg:
            set_scalar_or_enum(profile, "uplink_interval", int(cfg["uplink_interval"]))

        if "adr_algorithm_id" in cfg:
            set_scalar_or_enum(profile, "adr_algorithm_id", str(cfg["adr_algorithm_id"]))

        # Payload codec.
        codec_file = cfg.get("codec_file")
        codec_script = cfg.get("codec_script")

        if codec_file:
            codec_script = read_text_file(codec_file, self.config_dir)

        if codec_script:
            set_scalar_or_enum(profile, "payload_codec_runtime", cfg.get("payload_codec_runtime", "JS"), warn_missing=True)
            set_scalar_or_enum(profile, "payload_codec_script", codec_script, warn_missing=True)
        else:
            set_scalar_or_enum(profile, "payload_codec_runtime", cfg.get("payload_codec_runtime", "NONE"), warn_missing=True)
            set_scalar_or_enum(profile, "payload_codec_script", "", warn_missing=False)

        update_map_field(profile, "tags", cfg.get("tags", {}))

        return force or profile.SerializeToString() != before

    # -----------------------------------------------------------------------
    # Gateway
    # -----------------------------------------------------------------------

    def get_or_create_gateway(self, tenant_id: str, cfg: Dict[str, Any]) -> Optional[str]:
        gateway_id = cfg.get("gateway_id")
        if not gateway_id:
            log("Gateway", "-", "skipped", "gateway.gateway_id is not configured")
            return None

        gateway_id = require_hex(gateway_id, 16, "gateway.gateway_id")

        existing = self.get_gateway(gateway_id)

        if existing:
            gateway = existing.gateway
            changed = self.apply_gateway_config(gateway, tenant_id, cfg)

            if changed:
                if not self.dry_run:
                    req = api.UpdateGatewayRequest()
                    req.gateway.CopyFrom(gateway)
                    self.gateway_client.Update(req, metadata=self.auth)
                log("Gateway", gateway_id, "updated", gateway.name)
            else:
                log("Gateway", gateway_id, "exists", gateway.name)

            return gateway_id

        gateway = api.Gateway()
        self.apply_gateway_config(gateway, tenant_id, cfg, force=True)

        if self.dry_run:
            log("Gateway", gateway_id, "would-create")
            return gateway_id

        req = api.CreateGatewayRequest()
        req.gateway.CopyFrom(gateway)
        self.gateway_client.Create(req, metadata=self.auth)

        log("Gateway", gateway_id, "created", gateway.name)
        return gateway_id

    def get_gateway(self, gateway_id: str) -> Optional[Any]:
        try:
            return self.gateway_client.Get(
                api.GetGatewayRequest(gateway_id=gateway_id),
                metadata=self.auth,
            )
        except grpc.RpcError as exc:
            if is_not_found(exc):
                return None
            raise

    def apply_gateway_config(
        self,
        gateway: Any,
        tenant_id: str,
        cfg: Dict[str, Any],
        force: bool = False,
    ) -> bool:
        before = gateway.SerializeToString()

        gateway.gateway_id = require_hex(cfg["gateway_id"], 16, "gateway.gateway_id")
        gateway.tenant_id = tenant_id
        gateway.name = cfg.get("name", gateway.gateway_id)
        gateway.description = cfg.get("description", "Created by chirpstack-bootstrap")

        if "stats_interval" in cfg:
            gateway.stats_interval = int(cfg["stats_interval"])

        update_map_field(gateway, "tags", cfg.get("tags", {}))
        update_map_field(gateway, "metadata", cfg.get("metadata", {}))
        set_location(gateway, cfg.get("location"))

        return force or gateway.SerializeToString() != before

    # -----------------------------------------------------------------------
    # Devices
    # -----------------------------------------------------------------------

    def get_or_create_devices(
        self,
        application_id: str,
        profile_ids: Dict[str, str],
        devices_cfg: Iterable[Dict[str, Any]],
    ) -> None:
        for cfg in devices_cfg:
            self.get_or_create_device(application_id, profile_ids, cfg)

    def get_or_create_device(
        self,
        application_id: str,
        profile_ids: Dict[str, str],
        cfg: Dict[str, Any],
    ) -> None:
        name = cfg.get("name")
        dev_eui = require_hex(cfg.get("dev_eui", ""), 16, f"devices[{name}].dev_eui")
        profile_name = cfg.get("profile") or cfg.get("device_profile")

        if not name:
            fail(f"Device {dev_eui} must have name")

        if not profile_name:
            fail(f"Device {name} must have profile")

        if profile_name not in profile_ids:
            known = ", ".join(profile_ids.keys())
            fail(f"Device {name} references unknown profile '{profile_name}'. Known profiles: {known}")

        device_profile_id = profile_ids[profile_name]
        existing = self.get_device(dev_eui)

        if existing:
            device = existing.device
            changed = self.apply_device_config(device, application_id, device_profile_id, cfg)

            if changed:
                if not self.dry_run:
                    req = api.UpdateDeviceRequest()
                    req.device.CopyFrom(device)
                    self.device_client.Update(req, metadata=self.auth)
                log("Device", name, "updated", dev_eui)
            else:
                log("Device", name, "exists", dev_eui)

        else:
            device = api.Device()
            self.apply_device_config(device, application_id, device_profile_id, cfg, force=True)

            if not self.dry_run:
                req = api.CreateDeviceRequest()
                req.device.CopyFrom(device)
                self.device_client.Create(req, metadata=self.auth)

            log("Device", name, "created" if not self.dry_run else "would-create", dev_eui)

        self.create_or_update_device_keys(dev_eui, name, cfg)

    def get_device(self, dev_eui: str) -> Optional[Any]:
        try:
            return self.device_client.Get(
                api.GetDeviceRequest(dev_eui=dev_eui),
                metadata=self.auth,
            )
        except grpc.RpcError as exc:
            if is_not_found(exc):
                return None
            raise

    def apply_device_config(
        self,
        device: Any,
        application_id: str,
        device_profile_id: str,
        cfg: Dict[str, Any],
        force: bool = False,
    ) -> bool:
        before = device.SerializeToString()

        device.dev_eui = require_hex(cfg["dev_eui"], 16, f"device {cfg.get('name')}.dev_eui")
        device.name = cfg["name"]
        device.description = cfg.get("description", "Created by chirpstack-bootstrap")
        device.application_id = application_id
        device.device_profile_id = device_profile_id
        device.skip_fcnt_check = bool(cfg.get("skip_fcnt_check", False))
        device.is_disabled = bool(cfg.get("is_disabled", False))

        if cfg.get("join_eui"):
            device.join_eui = require_hex(cfg["join_eui"], 16, f"device {cfg.get('name')}.join_eui")

        update_map_field(device, "tags", cfg.get("tags", {}))
        update_map_field(device, "variables", cfg.get("variables", {}))

        return force or device.SerializeToString() != before

    # -----------------------------------------------------------------------
    # Device keys
    # -----------------------------------------------------------------------

    def create_or_update_device_keys(self, dev_eui: str, device_name: str, cfg: Dict[str, Any]) -> None:
        key = self.resolve_device_app_key(cfg)
        if not key:
            log("DeviceKeys", device_name, "skipped", "no app_key / app_key_env configured")
            return

        key = require_hex(key, 32, f"device {device_name} AppKey")
        root_key_field = cfg.get("root_key_field", "nwk_key")

        desired = api.DeviceKeys()
        desired.dev_eui = dev_eui

        if root_key_field == "app_key":
            desired.app_key = key
        elif root_key_field == "nwk_key":
            desired.nwk_key = key
        else:
            fail(f"Unsupported root_key_field for {device_name}: {root_key_field}")

        if cfg.get("gen_app_key"):
            desired.gen_app_key = require_hex(cfg["gen_app_key"], 32, f"device {device_name}.gen_app_key")

        existing = self.get_device_keys(dev_eui)

        if existing is None:
            if not self.dry_run:
                req = api.CreateDeviceKeysRequest()
                req.device_keys.CopyFrom(desired)
                self.device_client.CreateKeys(req, metadata=self.auth)
            log("DeviceKeys", device_name, "created" if not self.dry_run else "would-create", dev_eui)
            return

        current = existing.device_keys

        changed = (
            normalize_key(current.nwk_key) != normalize_key(desired.nwk_key)
            or normalize_key(current.app_key) != normalize_key(desired.app_key)
            or normalize_key(current.gen_app_key) != normalize_key(desired.gen_app_key)
        )

        if not changed:
            log("DeviceKeys", device_name, "exists", dev_eui)
            return

        if not self.dry_run:
            req = api.UpdateDeviceKeysRequest()
            req.device_keys.CopyFrom(desired)
            self.device_client.UpdateKeys(req, metadata=self.auth)

            if bool(cfg.get("flush_dev_nonces_on_key_change", True)):
                self.device_client.FlushDevNonces(
                    api.FlushDevNoncesRequest(dev_eui=dev_eui),
                    metadata=self.auth,
                )
                log("DeviceKeys", device_name, "updated", f"{dev_eui}; dev-nonces flushed")
            else:
                log("DeviceKeys", device_name, "updated", dev_eui)
        else:
            log("DeviceKeys", device_name, "would-update", dev_eui)

    def get_device_keys(self, dev_eui: str) -> Optional[Any]:
        try:
            return self.device_client.GetKeys(
                api.GetDeviceKeysRequest(dev_eui=dev_eui),
                metadata=self.auth,
            )
        except grpc.RpcError as exc:
            if is_not_found(exc):
                return None
            raise

    def resolve_device_app_key(self, cfg: Dict[str, Any]) -> Optional[str]:
        if cfg.get("app_key"):
            return str(cfg["app_key"])

        env_name = cfg.get("app_key_env")
        if env_name:
            return require_env(str(env_name))

        dev_eui = cfg.get("dev_eui")
        if dev_eui:
            default_env = f"APPKEY_{normalize_eui(dev_eui).upper()}"
            return os.getenv(default_env)

        return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def print_summary() -> None:
    print("\nBootstrap summary:")
    print("-" * 96)
    print(f"{'Kind':<18} {'Name':<34} {'Action':<14} Details")
    print("-" * 96)

    for item in RESULTS:
        print(f"{item.kind:<18} {item.name:<34} {item.action:<14} {item.details}")

    print("-" * 96)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bootstrap ChirpStack tenant, application, gateway and devices.")

    parser.add_argument(
        "--server",
        default=os.getenv("CHIRPSTACK_SERVER", "chirpstack.iot-system:8080"),
        help="ChirpStack gRPC API address. Default: env CHIRPSTACK_SERVER or chirpstack.iot-system:8080",
    )

    parser.add_argument(
        "--token",
        default=os.getenv("CHIRPSTACK_API_TOKEN"),
        help="ChirpStack API token. Default: env CHIRPSTACK_API_TOKEN",
    )

    parser.add_argument(
        "--config",
        default=os.getenv("CHIRPSTACK_BOOTSTRAP_CONFIG", "/config/devices.yaml"),
        help="Path to devices.yaml",
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned actions without writing to ChirpStack. Note: existing objects are still read.",
    )

    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if not args.token:
        fail("ChirpStack API token is required. Use --token or CHIRPSTACK_API_TOKEN env var.")

    config_path = Path(args.config).resolve()
    config_dir = config_path.parent
    cfg = load_config(config_path)

    print(f"Connecting to ChirpStack gRPC API: {args.server}", flush=True)
    print(f"Config: {config_path}", flush=True)
    if args.dry_run:
        print("Dry-run mode: writes are disabled", flush=True)

    bootstrap = ChirpStackBootstrap(
        server=args.server,
        api_token=args.token,
        config_dir=config_dir,
        dry_run=args.dry_run,
    )

    try:
        tenant_id = bootstrap.get_or_create_tenant(cfg["tenant"])
        application_id = bootstrap.get_or_create_application(tenant_id, cfg["application"])
        profile_ids = bootstrap.get_or_create_device_profiles(tenant_id, cfg["device_profiles"])
        bootstrap.get_or_create_gateway(tenant_id, cfg.get("gateway", {}))
        bootstrap.get_or_create_devices(application_id, profile_ids, cfg["devices"])

    except grpc.RpcError as exc:
        fail(f"gRPC API call failed: {grpc_error_message(exc)}")

    print_summary()
    print("Bootstrap completed successfully.", flush=True)


if __name__ == "__main__":
    main()