from __future__ import annotations

import json
from importlib.resources import files

import pytest
from sushy_tools.emulator import main
from sushy_tools.emulator.resources.systems import libvirtdriver


def test_system_template_advertises_nmi_reset() -> None:
    template = files("sushy_tools.emulator").joinpath("templates/system.json")
    rendered = template.read_text(encoding="utf-8")
    rendered = main.app.jinja_env.from_string(rendered).render(
        identity="host",
        name="host",
        uuid="00000000-0000-0000-0000-000000000000",
        feature_set="minimum",
        chassis=(),
        managers=(),
    )

    system = json.loads(rendered)

    assert "Nmi" in system["Actions"]["#ComputerSystem.Reset"]["ResetType@Redfish.AllowableValues"]


def test_reset_handler_forwards_nmi_to_systems_driver(monkeypatch: pytest.MonkeyPatch) -> None:
    class SystemsDriver:
        def __init__(self) -> None:
            self.calls: list[tuple[str, str]] = []

        def set_power_state(self, identity: str, reset_type: str) -> None:
            self.calls.append((identity, reset_type))

    driver = SystemsDriver()
    monkeypatch.setattr(main.Application, "systems", property(lambda _app: driver))

    response = main.app.test_client().post(
        "/redfish/v1/Systems/host/Actions/ComputerSystem.Reset",
        json={"ResetType": "Nmi"},
    )

    assert response.status_code == 204
    assert driver.calls == [("host", "Nmi")]


@pytest.mark.parametrize("active, expected_nmi_count", [(True, 1), (False, 0)])
def test_libvirt_driver_injects_nmi_only_for_active_domains(
    active: bool, expected_nmi_count: int, monkeypatch: pytest.MonkeyPatch
) -> None:
    class Domain:
        def __init__(self, active: bool) -> None:
            self._active = active
            self.inject_nmi_count = 0

        def isActive(self) -> bool:
            return self._active

        def injectNMI(self) -> None:
            self.inject_nmi_count += 1

    domain = Domain(active)
    driver = libvirtdriver.LibvirtDriver()
    monkeypatch.setattr(driver, "_get_domain", lambda _identity: domain)

    driver.set_power_state("host", "Nmi")

    assert domain.inject_nmi_count == expected_nmi_count
