from . import (
    menu_10_backup,
    menu_1_status,
    menu_2_xray_user,
    menu_3_ssh_user,
    menu_4_network,
    menu_4_xray_quota,
    menu_5_domain,
    menu_5_ssh_quota,
    menu_6_speedtest,
    menu_7_security,
    menu_8_maintenance,
    menu_12_traffic,
)

MENU_HANDLERS = {
    "1": menu_2_xray_user.handle,
    "2": menu_3_ssh_user.handle,
    "3": menu_4_xray_quota.handle,
    "4": menu_5_ssh_quota.handle,
    "5": menu_4_network.handle,
    "6": menu_5_domain.handle,
    "7": menu_6_speedtest.handle,
    "8": menu_7_security.handle,
    "9": menu_8_maintenance.handle,
    "10": menu_12_traffic.handle,
    "11": menu_1_status.handle,
    "12": menu_10_backup.handle,
}
