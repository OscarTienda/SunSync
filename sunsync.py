import os
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from importlib.metadata import PackageNotFoundError, version
from typing import Optional, Tuple

try:
    __version__ = version("sunsync")
except PackageNotFoundError:  # running from a source checkout, not installed
    __version__ = "0.2.3"

from config.constants import DEFAULT_IMAGE, SOURCE_COLORS, RESET_COLOR
from sunshine.sunshine import (
    detect_apollo_installation,
    detect_sunshine_installation,
    ensure_authenticated,
    get_api_connection,
    get_api_url,
    get_covers_path,
    get_existing_apps,
    get_existing_apps_full,
    delete_app,
    get_running_servers,
    get_server_display_name,
    is_server_running,
    add_game_to_sunshine,
    prime_existing_apps_cache,
    clear_existing_apps_cache,
    save_api_connection,
    set_api_connection,
    set_installation_type,
    set_server_name,
)
from utils.utils import handle_interrupt
from utils.input import get_user_input, get_yes_no_input, get_user_selection
from utils.steamgriddb import manage_api_key, download_image_from_steamgriddb
from launchers.heroic import list_heroic_games, get_heroic_command
from launchers.lutris import list_lutris_games, get_lutris_command, is_lutris_running
from launchers.bottles import detect_bottles_installation, list_bottles_games
from launchers.steam import detect_steam_installation, list_steam_games, get_steam_command
from launchers.faugus import detect_faugus_installation, list_faugus_games
from launchers.ryubing import detect_ryubing_installation, list_ryubing_games
from launchers.retroarch import detect_retroarch_installation, list_retroarch_games
from launchers.eden import detect_eden_installation, list_eden_games
from display.manager import (
    clear_external_prep_scripts,
    get_external_prep_commands,
    set_external_prep_scripts,
)


def parse_args(argv=None):
    def api_port_arg(value: str) -> int:
        port = int(value)
        if not 1 <= port <= 65535:
            raise argparse.ArgumentTypeError("port must be between 1 and 65535")
        return port

    parser = argparse.ArgumentParser(
        description="Import launcher games into Sunshine.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"sunsync {__version__}",
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        help="Launch the graphical interface.",
    )
    parser.add_argument(
        "--cover",
        action="store_true",
        help="Automatically download SteamGridDB covers for added games.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Automatically add all listed games (skips selection prompt).",
    )
    parser.add_argument(
        "--sunshine-host",
        default="",
        help="Override the Sunshine/Apollo web UI host.",
    )
    parser.add_argument(
        "--sunshine-port",
        type=api_port_arg,
        help="Override the Sunshine/Apollo web UI port. Usually 47990.",
    )
    subparsers = parser.add_subparsers(dest="command")

    display_parser = subparsers.add_parser(
        "display",
        help="Configure prep/undo scripts injected into game launches.",
    )
    display_parser.set_defaults(command="display")
    display_subparsers = display_parser.add_subparsers(dest="display_action")

    external_prep_parser = display_subparsers.add_parser(
        "external-prep",
        help="Configure external pre/post scripts (e.g. krfb-virtualmonitor).",
    )
    external_prep_subs = external_prep_parser.add_subparsers(dest="external_prep_action")
    external_prep_set = external_prep_subs.add_parser("set", help="Set the pre/post scripts.")
    external_prep_set.add_argument(
        "--do", required=True, dest="prep_do",
        help="Path to the pre-launch script (runs before the game).",
    )
    external_prep_set.add_argument(
        "--undo", default="", dest="prep_undo",
        help="Path to the post-launch script (runs when the game exits).",
    )
    external_prep_subs.add_parser("clear", help="Remove external prep script configuration.")
    external_prep_subs.add_parser("status", help="Show current external prep script configuration.")

    subparsers.add_parser("list", help="List apps configured in Sunshine/Apollo.")
    remove_parser = subparsers.add_parser("remove", help="Remove an app by name.")
    remove_parser.add_argument("name", help="Exact name of the app to remove.")

    return parser.parse_args(argv)


def handle_display_command(args) -> int:
    action = args.display_action

    if action == "external-prep" or action is None:
        external_action = getattr(args, "external_prep_action", None)

        if external_action == "set":
            do_script = os.path.expanduser(args.prep_do)
            undo_script = os.path.expanduser(getattr(args, "prep_undo", "") or "")
            set_external_prep_scripts(do_script, undo_script)
            print("External prep scripts configured.")
            print(f"  do:   {do_script}")
            print(f"  undo: {undo_script or '(none)'}")
            return 0

        if external_action == "clear":
            clear_external_prep_scripts()
            print("External prep scripts cleared.")
            return 0

        commands = get_external_prep_commands()
        if not commands:
            print("No external prep scripts configured.")
            print("  Set them with: display external-prep set --do <script> --undo <script>")
        else:
            print("External prep scripts:")
            for cmd in commands:
                print(f"  do:   {cmd.get('do') or '(none)'}")
                print(f"  undo: {cmd.get('undo') or '(none)'}")
        return 0

    print(f"Unknown display action: {action}")
    return 1


def prepare_server(args) -> Optional[str]:
    """Detect, select and authenticate a running Sunshine/Apollo server.

    Non-interactive server selection (defaults to Sunshine when both run) — the
    management subcommands are quick one-shot operations, not the guided add
    flow. Returns the chosen server name, or None if setup fails.
    """
    sunshine_installed, sunshine_install_type = detect_sunshine_installation()
    apollo_installed = detect_apollo_installation()
    if not sunshine_installed and not apollo_installed:
        print("Error: No Sunshine or Apollo installation detected.")
        return None

    running = get_running_servers()
    if not running:
        print("Error: Sunshine or Apollo is not running. Please start it and try again.")
        return None

    server_name = "sunshine" if "sunshine" in running else running[0]
    if server_name == "sunshine":
        set_installation_type(sunshine_install_type)
    else:
        set_installation_type("native")

    set_server_name(server_name)
    if args.sunshine_host or args.sunshine_port is not None:
        set_api_connection(host=args.sunshine_host or None, port=args.sunshine_port)

    if not ensure_authenticated(allow_prompt=True):
        print(f"Error: Could not authenticate with {get_server_display_name()}.")
        return None
    return server_name


def _print_app_list() -> int:
    apps = get_existing_apps_full()
    if not apps:
        print(f"No apps configured in {get_server_display_name()}.")
        return 0
    for app in sorted(apps, key=lambda a: str(a.get("name", "")).lower()):
        print(f"{app.get('index')}: {app.get('name')}")
    return 0


def _remove_app_by_name(name: str) -> int:
    apps = get_existing_apps_full()
    matches = [a for a in apps if a.get("name") == name]
    if not matches:
        print(f"No app named '{name}' found in {get_server_display_name()}.")
        return 1
    ok, error = delete_app(matches[0]["index"])
    if not ok:
        print(f"Error removing '{name}': {error}")
        return 1
    print(f"Removed '{name}' from {get_server_display_name()}.")
    return 0


def handle_list_command(args) -> int:
    if prepare_server(args) is None:
        return 1
    return _print_app_list()


def handle_remove_command(args) -> int:
    if prepare_server(args) is None:
        return 1
    return _remove_app_by_name(args.name)


def main(argv=None):
    def prompt_server_connection() -> Tuple[str, int]:
        current_host, current_port = get_api_connection()
        print(f"{get_server_display_name()} web UI address: {get_api_url()}")
        print("Use the HTTPS web UI port here. The default is 47990.")

        host = input(f"Host [{current_host}]: ").strip() or current_host
        port = get_user_input(
            f"Port [{current_port}]: ",
            lambda value: current_port if value.strip() == "" else _validate_port_input(value),
            "Invalid port. Enter a number from 1 to 65535.",
        )
        return host, port

    def _validate_port_input(value: str) -> int:
        port = int(value.strip())
        if not 1 <= port <= 65535:
            raise ValueError()
        return port

    def configure_connection_and_retry_auth(server_name: str) -> bool:
        if server_name != "sunshine":
            return False

        while True:
            current_url = get_api_url()
            prompt = (
                f"Authentication failed using {get_server_display_name()} at {current_url}. "
                "Configure a different web UI host or port and try again?"
            )
            if not get_yes_no_input(prompt, default=True):
                return False

            host, port = prompt_server_connection()
            set_api_connection(host=host, port=port)

            if ensure_authenticated(allow_prompt=True):
                save_api_connection(host, port, server_name=server_name)
                print(f"Saved {get_server_display_name()} web UI address: {get_api_url()}")
                return True

    args = parse_args(argv)

    if getattr(args, "gui", False):
        try:
            from gui import run_gui
        except ImportError as exc:
            print(f"Error: GUI requires PyQt6. Install it with: pip install PyQt6\n{exc}")
            return
        run_gui()
        return

    if args.command == "display":
        raise SystemExit(handle_display_command(args))

    if args.command == "list":
        raise SystemExit(handle_list_command(args))

    if args.command == "remove":
        raise SystemExit(handle_remove_command(args))

    try:
        sunshine_installed, sunshine_install_type = detect_sunshine_installation()
        apollo_installed = detect_apollo_installation()
        if not sunshine_installed and not apollo_installed:
            print("Error: No Sunshine or Apollo installation detected.")
            return

        running_servers = get_running_servers()
        if not running_servers:
            print("Error: Sunshine or Apollo is not running. Please start it and try again.")
            return

        if "sunshine" in running_servers and "apollo" in running_servers:
            while True:
                choice = input("Both Sunshine and Apollo are running. Use (1) Sunshine or (2) Apollo? ").strip().lower()
                if choice in ("1", "sunshine", "s"):
                    server_name = "sunshine"
                    break
                if choice in ("2", "apollo", "a"):
                    server_name = "apollo"
                    break
                print("Please enter 1 for Sunshine or 2 for Apollo.")
        else:
            server_name = running_servers[0]

        if server_name == "sunshine":
            if not sunshine_installed:
                print("Error: Sunshine is not installed.")
                return
            set_installation_type(sunshine_install_type)
        else:
            if not apollo_installed:
                print("Error: Apollo is not installed.")
                return
            set_installation_type("native")

        set_server_name(server_name)
        if args.sunshine_host or args.sunshine_port is not None:
            set_api_connection(
                host=args.sunshine_host or None,
                port=args.sunshine_port,
            )
        if not is_server_running(server_name):
            print(f"Error: {server_name.title()} is not running. Please start it and try again.")
            return

        COVERS_PATH = get_covers_path()
        os.makedirs(COVERS_PATH, exist_ok=True)

        authenticated = ensure_authenticated(allow_prompt=True)
        if not authenticated:
            authenticated = configure_connection_and_retry_auth(server_name)

        if not authenticated:
            print("Error: Could not obtain valid authentication. Exiting.")
            return

        if args.sunshine_host or args.sunshine_port is not None:
            save_api_connection(
                args.sunshine_host or None,
                args.sunshine_port,
                server_name=server_name,
            )

        lutris_command = get_lutris_command()
        heroic_command, _ = get_heroic_command()
        bottles_installed = detect_bottles_installation()
        steam_installed, _ = detect_steam_installation()
        steam_command = get_steam_command() if steam_installed else ""
        faugus_installed = detect_faugus_installation()
        ryubing_installed = detect_ryubing_installation()
        retroarch_installed = detect_retroarch_installation()
        eden_installed = detect_eden_installation()

        if not lutris_command and not heroic_command and not bottles_installed and not steam_command and not faugus_installed and not ryubing_installed and not retroarch_installed and not eden_installed:
            print("No Lutris, Heroic, Bottles, Steam, Faugus, Ryubing, RetroArch, or Eden installation detected.")
            return

        if lutris_command and is_lutris_running():
            print("Error: Lutris is currently running. Please close Lutris and try again.")
            return

        with ThreadPoolExecutor() as executor:
            futures = {}
            if lutris_command:
                futures["Lutris"] = executor.submit(list_lutris_games)
            if heroic_command:
                futures["Heroic"] = executor.submit(list_heroic_games)
            if bottles_installed:
                futures["Bottles"] = executor.submit(list_bottles_games)
            if steam_command:
                futures["Steam"] = executor.submit(list_steam_games)
            if faugus_installed:
                futures["Faugus"] = executor.submit(list_faugus_games)
            if ryubing_installed:
                futures["Ryubing"] = executor.submit(list_ryubing_games)
            if retroarch_installed:
                futures["RetroArch"] = executor.submit(list_retroarch_games)
            if eden_installed:
                futures["Eden"] = executor.submit(list_eden_games)

            all_games = []
            for source, future in futures.items():
                result = future.result()
                if source == "Lutris":
                    all_games.extend([(game_id, game_name, "Lutris", "Lutris") for game_id, game_name in result])
                elif source == "Heroic":
                    all_games.extend([(game_id, game_name, "Heroic", runner) for game_id, game_name, _, runner in result])
                elif source == "Bottles":
                    all_games.extend(result)
                elif source == "Steam":
                    all_games.extend([(game_id, game_name, "Steam", "Steam") for game_id, game_name in result])
                elif source == "Faugus":
                    all_games.extend(result)
                elif source == "Ryubing":
                    all_games.extend([(game_id, game_name, "Ryubing", "Ryubing") for game_id, game_name in result])
                elif source == "RetroArch":
                    all_games.extend([
                        (game_path, game_name, "RetroArch", core_info)
                        for game_path, game_name, core_info in result
                    ])
                elif source == "Eden":
                    all_games.extend([(game_id, game_name, "Eden", "Eden") for game_id, game_name in result])

        if not all_games:
            print("No games found in any detected launcher.")
            return

        active_sources = sorted({display_source for _, _, display_source, _ in all_games})
        if len(active_sources) == 1:
            games_found_message = f"Games found in {active_sources[0]}:"
        elif len(active_sources) == 2:
            games_found_message = f"Games found in {active_sources[0]} and {active_sources[1]}:"
        else:
            games_found_message = f"Games found in {', '.join(active_sources[:-1])} and {active_sources[-1]}:"
        print(games_found_message)

        existing_apps = get_existing_apps()
        existing_game_names = {app["name"] for app in existing_apps}

        all_games.sort(key=lambda x: x[1])

        for idx, (_, game_name, display_source, source) in enumerate(all_games):
            status = f"(already in {get_server_display_name()})" if game_name in existing_game_names else ""
            if len(futures) > 1:
                source_color = SOURCE_COLORS.get(display_source, "")
                source_info = f"{source_color}({display_source}){RESET_COLOR}"
                print(f"{idx + 1}. {game_name} {source_info} {status}")
            else:
                print(f"{idx + 1}. {game_name} {status}")

        if args.all:
            selected_indices = list(range(len(all_games)))
        else:
            selected_indices = get_user_selection([(game_id, game_name) for game_id, game_name, _, _ in all_games])

        selected_games = [all_games[i] for i in selected_indices if all_games[i][1] not in existing_game_names]

        if not selected_games:
            print(f"No new games to add to {get_server_display_name()} configuration.")
            return

        valid_selected_games = []
        for game_id, game_name, display_source, source in selected_games:
            if display_source == "RetroArch":
                core_info = source if isinstance(source, dict) else {}
                core_path = (core_info.get("core_path", "") or "").strip()
                core_name = (core_info.get("core_name", "") or "").strip()
                if core_path.upper() == "DETECT" or core_name.upper() == "DETECT" or not core_path:
                    print(
                        f"Error: RetroArch core not set for '{game_name}'. "
                        f"Please associate the game with a core in RetroArch before adding it to {get_server_display_name()}."
                    )
                    continue
            valid_selected_games.append((game_id, game_name, display_source, source))

        if not valid_selected_games:
            print("No games ready to add. Please resolve the reported issues and try again.")
            return

        download_images = args.cover or get_yes_no_input("Do you want to download images from SteamGridDB? (y/n): ")
        api_key = manage_api_key() if download_images else None

        from utils.images import get_local_cover, prepare_sunshine_cover
        from display.manager import get_prefer_steamgriddb
        prefer_steamgriddb = get_prefer_steamgriddb()

        games_added = False
        prime_existing_apps_cache()
        with ThreadPoolExecutor() as executor:
            futures = {}
            for game_id, game_name, display_source, source in valid_selected_games:
                # Resolve local cover unless SteamGridDB is preferred
                local_cover = None
                if not prefer_steamgriddb:
                    try:
                        local_cover = prepare_sunshine_cover(
                            get_local_cover(game_id, display_source), game_name
                        )
                    except Exception:
                        pass

                if local_cover:
                    add_game_to_sunshine(game_id, game_name, local_cover, source)
                    games_added = True
                elif download_images and api_key:
                    future = executor.submit(download_image_from_steamgriddb, game_name, api_key)
                    futures[future] = (game_id, game_name, source)
                else:
                    add_game_to_sunshine(game_id, game_name, DEFAULT_IMAGE, source)
                    games_added = True

            for future in as_completed(futures):
                game_id, game_name, source = futures[future]
                try:
                    image_path = future.result()
                except Exception as e:
                    print(f"Error downloading image for {game_name}: {e}")
                    image_path = DEFAULT_IMAGE

                add_game_to_sunshine(game_id, game_name, image_path, source)
                games_added = True

        clear_existing_apps_cache()
        if games_added:
            print(f"Games added to {get_server_display_name()} successfully.")
        else:
            print(f"No new games were added to {get_server_display_name()}.")

    except (KeyboardInterrupt, EOFError):
        handle_interrupt()


if __name__ == "__main__":
    main()
