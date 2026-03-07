from .menu_3_quota import handle_scoped


def handle(action: str, params: dict, settings) -> dict:
    return handle_scoped(action, params, settings, scope="ssh")
