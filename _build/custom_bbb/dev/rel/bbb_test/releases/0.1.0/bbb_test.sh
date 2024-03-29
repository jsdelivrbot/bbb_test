#!/bin/sh

set -e

# Set VERBOSE to enable verbose logging of the boot script
#VERBOSE=true
if [ ! -z $DEBUG_BOOT ]; then
    set -x
fi;

my_readlink_f() {
    TARGET_FILE="$1"
    cd $(dirname "$TARGET_FILE")
    TARGET_FILE=$(basename "$TARGET_FILE")

    # Iterate down a (possible) chain of symlinks
    while [ -L "$TARGET_FILE" ]
    do
        TARGET_FILE=$(readlink "$TARGET_FILE")
        cd $(dirname "$TARGET_FILE")
        TARGET_FILE=$(basename "$TARGET_FILE")
    done
    # Compute the canonicalized name by finding the physical path
    # for the directory we're in and appending the target file.
    PHYS_DIR=$(pwd -P)
    RESULT="$PHYS_DIR/$TARGET_FILE"
    echo "$RESULT"
}

# Path to this script
if uname | grep -q 'Darwin'; then
  # on OSX, best to install coreutils from homebrew or similar
  # to get greadlink
  if command -v greadlink >/dev/null 2>&1; then
    SCRIPT="${SCRIPT:-$(greadlink -f "$0")}"
  else
    SCRIPT="${SCRIPT:-$(my_readlink_f "$0")}"
  fi
else
  SCRIPT="${SCRIPT:-$(readlink -f "$0" )}"
fi

# Parent directory of this script
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "${SCRIPT}")}"
# Root directory of all releases
RELEASE_ROOT_DIR="${RELEASE_ROOT_DIR:-$(dirname $(dirname ${SCRIPT_DIR}))}"

# Disable flow control for run_erl
# Flow control can cause several problems. On Linux, if you
# accidentally hit Ctrl-S (instead of Ctrl-D to detach) and
# then some other key, the entire beam process will hang when
# attempting to write to stdout. On Solaris, the beam process
# will hang on writing if ScrollLock is on.
RUN_ERL_DISABLE_FLOWCNTRL="${RUN_ERL_DISABLE_FLOWCNTRL:-true}"
# Name of the release
REL_NAME="${REL_NAME:-bbb_test}"
# Current version of the release
REL_VSN="${REL_VSN:-0.1.0}"
# Current version of ERTS being used
# If this is not present/unset, it will be detected
ERTS_VSN="${ERTS_VSN:-8.2}"
# VM code loading mode, embedded by default, can also be interactive
# See http://erlang.org/doc/man/code.html
CODE_LOADING_MODE="${CODE_LOADING_MODE:-embedded}"
# Path to start_erl.data
START_ERL_DATA="${START_ERL_DATA:-$RELEASE_ROOT_DIR/releases/start_erl.data}"
# Directory containing the current version of this release
REL_DIR="${REL_DIR:-$RELEASE_ROOT_DIR/releases/$REL_VSN}"
# The lib directory for this release
REL_LIB_DIR="${REL_LIB_DIR:-$RELEASE_ROOT_DIR/lib}"
# Options passed to erl
ERL_OPTS="${ERL_OPTS:-}"
# When stdout is piped to a file, this is the directory those files will
# be stored in. defaults to /log in the release root directory

# RELEASE_MUTABLE_DIR
RELEASE_MUTABLE_DIR="${RELEASE_MUTABLE_DIR:-$RELEASE_ROOT_DIR/var}"

RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-$RELEASE_MUTABLE_DIR/log}"
# A string of extra options to pass to erl, here for plugins
EXTRA_OPTS="${EXTRA_OPTS:-}"

# Pre-start/stop event hook paths
PRE_CONFIGURE_HOOKS="$REL_DIR/hooks/pre_configure.d"
PRE_START_HOOKS="$REL_DIR/hooks/pre_start.d"
POST_START_HOOKS="$REL_DIR/hooks/post_start.d"
PRE_STOP_HOOKS="$REL_DIR/hooks/pre_stop.d"
POST_STOP_HOOKS="$REL_DIR/hooks/post_stop.d"
PRE_UPGRADE_HOOKS="$REL_DIR/hooks/pre_upgrade.d"
POST_UPGRADE_HOOKS="$REL_DIR/hooks/post_upgrade.d"

# Get node pid
get_pid() {
    if output="$(nodetool rpcterms os getpid)"
    then
        echo "$output" | sed -e 's/"//g'
        return 0
    else
        echo "$output"
        return 1
    fi
}

# Generate a unique nodename
gen_nodename() {
    id="longname$(gen_id)-${NAME}"
    "$BINDIR/erl" -boot start_clean -eval '[Host] = tl(string:tokens(atom_to_list(node()),"@")), io:format("~s~n", [Host]), halt()' -noshell ${NAME_TYPE} $id
}

# Generate a random id
gen_id() {
    od -t x -N 4 /dev/urandom | head -n1 | awk '{print $2}'
}

# Control a node
# Use like `nodetool "ping"`
nodetool() {
    command="$1"; shift
    name=${PEERNAME:-$NAME}
    "$ERTS_DIR/bin/escript" "$ROOTDIR/bin/nodetool" "$NAME_TYPE" "$name" \
                            -setcookie "$COOKIE" "$command" $@
}



# Run an escript in the node's environment
# Use like `escript "path/to/escript"`
escript() {
    shift; scriptpath="$1"; shift
    export RELEASE_ROOT_DIR

    "$ERTS_DIR/bin/escript" "$ROOTDIR/$scriptpath" $@
}

# Private. Load target cookie, either from vm.args or $HOME/.cookie
_load_cookie() {
    COOKIE_ARG="$(grep '^-setcookie' "$VMARGS_PATH" || true)"
    DEFAULT_COOKIE_FILE="$HOME/.erlang.cookie"
    if [ -z "$COOKIE_ARG" ]; then
        if [ -f "$DEFAULT_COOKIE_FILE" ]; then
            COOKIE="$(cat "$DEFAULT_COOKIE_FILE")"
        fi
    else
        # Extract cookie name from COOKIE_ARG
        COOKIE="$(echo "$COOKIE_ARG" | awk '{print $2}')"
    fi
}

# Private. Ensure that cookie is set.
_check_cookie() {
    # Attempt reloading cookie in case it has been set in a hook
    if [ -z "$COOKIE" ]; then
        _load_cookie
    fi
    # Die if cookie is still not set, as connecting via distribution will fail
    if [ -z "$COOKIE" ]; then
        printf "a secret cookie must be provided in one of the following ways:\n  - with vm.args using the -setcookie parameter,\n  or\n  by writing the cookie to '$DEFAULT_COOKIE_FILE', with permissions set to 0400"
        exit 1
    fi
}

# Private. For setting up the Erlang runtime to use
_init_erts_config() {
    if [ -z "$ERTS_VSN" ]; then
        set +e # temporarily disable so we can display a nice error message to the user
        __erl="$(which erl)"
        set -e
        if [ -z "${__erl}"  ]; then
            echo 'erlang runtime not found. If erlang is installed check your $PATH. aborting.'
            exit 1
        fi
        export ROOTDIR="$("$__erl" -boot start_clean -eval 'io:format("~s~n", [code:root_dir()]), halt().' -noshell)"
        export ERTS_VSN="$(_get_erts_vsn)"
        export ERTS_DIR="$ROOTDIR"/"erts-$ERTS_VSN"
    else
        __erts_dir="$RELEASE_ROOT_DIR/erts-$ERTS_VSN"
        if [ -d "$__erts_dir" ]; then
            export ROOTDIR="$RELEASE_ROOT_DIR"
            export ERTS_DIR="$__erts_dir"
        else
            unset ERTS_VSN
            _init_erts_config
        fi
    fi
}

# Private. For determining the version of ERTS available to the release
# This is only ever called if ERTS_VSN is not set
_get_erts_vsn() {
    if [ -z "$ERTS_VSN" ]; then
        "$ROOTDIR"/bin/erl \
            -boot start_clean \
            -eval 'Ver = erlang:system_info(version), io:format("~s~n", [Ver]), halt()' \
            -noshell
    else
        echo "$ERTS_VSN"
    fi
}

# Private. Gets a list of code paths for this release
_get_code_paths() {
    "$ERTS_DIR/bin/escript" "$ROOTDIR/bin/release_utils.escript" "get_code_paths" "$ROOTDIR" "$ERTS_DIR" "$REL_NAME" "$REL_VSN"
}

# Private. Open a shell on a remote node
_rem_sh() {
    # Generate a unique id used to allow multiple remsh to the same node
    # transparently
    id="remsh$(gen_id)-${NAME}"

    # Get the node's ticktime so that we use the same thing.
    TICKTIME="$(nodetool rpcterms net_kernel get_net_ticktime)"

    # Setup remote shell command to control node
    if [ ! -z "$USE_ERL_SHELL" ]; then
        exec "$BINDIR/erl" \
            -hidden \
            -boot start_clean -boot_var ERTS_LIB_DIR "$ERTS_LIB_DIR" \
            -kernel net_ticktime $TICKTIME \
            "$NAME_TYPE" "$id" -remsh "$NAME" -setcookie "$COOKIE"
    else
        __code_paths=$(_get_code_paths)
        exec "$BINDIR/erl" \
            -pa "$CONSOLIDATED_DIR" \
            ${__code_paths} \
            -hidden -noshell \
            -boot start_clean -boot_var ERTS_LIB_DIR "$ERTS_LIB_DIR" \
            -kernel net_ticktime $TICKTIME \
            -user Elixir.IEx.CLI "$NAME_TYPE" "$id" -setcookie "$COOKIE" \
            -extra --no-halt +iex -"$NAME_TYPE" "$id" --cookie "$COOKIE" --remsh "$NAME"
    fi
}

# Output a start command for the last argument of run_erl
_start_command() {
    printf "exec \"%s\" \"%s\" -- %s %s" "$RELEASE_ROOT_DIR/bin/$REL_NAME" \
           "$START_OPTION" "${ARGS}" "${EXTRA_OPTS}"
}

# Do a textual replacement of ${VAR} occurrences in $1 and pipe to $2
_replace_os_vars() {
    awk '
        function escape(s) {
            gsub(/'\&'/, "\\\\&", s);
            return s;
        }
        {
            while(match($0,"[$]{[^}]*}")) {
                var=substr($0,RSTART+2,RLENGTH-3);
                gsub("[$]{"var"}", escape(ENVIRON[var]))
            }
        }1' < "$1" > "$1.bak"
    mv -- "$1.bak" "$1"
}

# Private. Run hooks from directory.
_run_hooks_from_dir() {
   if [ -d "$1" ]; then
      for file in $1/[0-9a-zA-Z]*.sh; do
        [ -f "$file" ] || continue
        . "$file"
      done
   fi
}

# Private. Sets config paths for sys.config and vm.args,
# and ensures that env var replacements are performed
_init_configs() {
    # Set VMARGS_PATH, the path to the vm.args file to use
    # Use $RELEASE_CONFIG_DIR/vm.args if exists, otherwise releases/VSN/vm.args
    if [ -z "$VMARGS_PATH" ]; then
        if [ -f "$RELEASE_CONFIG_DIR/vm.args" ]; then
            export VMARGS_PATH="$RELEASE_CONFIG_DIR/vm.args"
        else
            export VMARGS_PATH="$REL_DIR/vm.args"
        fi
        export SRC_VMARGS_PATH="$VMARGS_PATH"
    else
        if [ "$VMARGS_PATH" != "$RELEASE_MUTABLE_DIR/vm.args" ]; then
            export SRC_VMARGS_PATH="$VMARGS_PATH"
        else
            if [ -f "$RELEASE_CONFIG_DIR/vm.args" ]; then
                export VMARGS_PATH="$RELEASE_CONFIG_DIR/vm.args"
            else
                export VMARGS_PATH="$REL_DIR/vm.args"
            fi
            export SRC_VMARGS_PATH="$VMARGS_PATH"
        fi
    fi
    if [ "$SRC_VMARGS_PATH" != "$RELEASE_MUTABLE_DIR/vm.args" ]; then
        echo "#### Generated - edit/create $RELEASE_CONFIG_DIR/vm.args instead." \
            >  "$RELEASE_MUTABLE_DIR/vm.args"
        cat  "$SRC_VMARGS_PATH"                              \
            >> "$RELEASE_MUTABLE_DIR/vm.args"
        export VMARGS_PATH="$RELEASE_MUTABLE_DIR"/vm.args
    fi
    if [ $REPLACE_OS_VARS ]; then
        _replace_os_vars "$VMARGS_PATH"
    fi

    # Set SYS_CONFIG_PATH, the path to the sys.config file to use
    # Use $RELEASE_CONFIG_DIR/sys.config if exists, otherwise releases/VSN/sys.config
    if [ -z "$SYS_CONFIG_PATH" ]; then
        if [ -f "$RELEASE_CONFIG_DIR/sys.config" ]; then
            export SYS_CONFIG_PATH="$RELEASE_CONFIG_DIR/sys.config"
        else
            export SYS_CONFIG_PATH="$REL_DIR/sys.config"
        fi
        export SRC_SYS_CONFIG_PATH="$SYS_CONFIG_PATH"
    else
        if [ "$SYS_CONFIG_PATH" != "$RELEASE_MUTABLE_DIR/sys.config" ]; then
            export SRC_SYS_CONFIG_PATH="$SYS_CONFIG_PATH"
        else
            if [ -f "$RELEASE_CONFIG_DIR/sys.config" ]; then
                export SYS_CONFIG_PATH="$RELEASE_CONFIG_DIR/sys.config"
            else
                export SYS_CONFIG_PATH="$REL_DIR/sys.config"
            fi
            export SRC_SYS_CONFIG_PATH="$SYS_CONFIG_PATH"
        fi
    fi
    if [ "$SRC_SYS_CONFIG_PATH" != "$RELEASE_MUTABLE_DIR/sys.config" ]; then
        (echo "%% Generated - edit/create $RELEASE_CONFIG_DIR/sys.config instead."; \
        cat  "$SRC_SYS_CONFIG_PATH")                              \
            > "$RELEASE_MUTABLE_DIR/sys.config"
        export SYS_CONFIG_PATH="$RELEASE_MUTABLE_DIR"/sys.config
    fi
    if [ $REPLACE_OS_VARS ]; then
        _replace_os_vars "$SYS_CONFIG_PATH"
    fi
}

# If TERM is not set, set it to xterm
if [ -z "$TERM" ]; then
    export TERM=xterm
fi

# Make sure ERTS configuration is set
_init_erts_config
echo "$ERTS_VSN $REL_VSN" > "$START_ERL_DATA"

# Allow override of where to read configuration from
# By default it's RELEASE_ROOT_DIR
if [ -z "$RELEASE_CONFIG_DIR" ]; then
    export RELEASE_CONFIG_DIR="$RELEASE_ROOT_DIR"
fi

# Make sure directories exist
mkdir -p "$RELEASE_MUTABLE_DIR"
echo "Files in this directory are regenerated frequently, edits will be lost" \
    > "$RELEASE_MUTABLE_DIR/WARNING_README"
mkdir -p "$RUNNER_LOG_DIR"

# Make sure config paths are setup
_init_configs

# Extract the target node name from node.args
# Should be `-sname somename` or `-name somename@somehost`
export NAME_ARG="$(egrep '^-s?name' "$VMARGS_PATH" || true)"
if [ -z "$NAME_ARG" ]; then
    echo "vm.args needs to have either -name or -sname parameter."
    exit 1
fi

# Extract the name type and name from the NAME_ARG for REMSH
# NAME_TYPE should be -name or -sname
export NAME_TYPE="$(echo "$NAME_ARG" | awk '{print $1}')"
# NAME will be either `somename` or `somename@somehost`
export NAME="$(echo "$NAME_ARG" | awk '{print $2}')"

# Where the pipe will be stored when using `start`
# This is used so you can attach the running application to the current
# shell using `attach`
PIPE_DIR="${PIPE_DIR:-$RELEASE_MUTABLE_DIR/erl_pipes/$NAME/}"

# Extract the target cookie
_load_cookie

export ROOTDIR="$RELEASE_ROOT_DIR"
export BINDIR="$ERTS_DIR/bin"
export EMU="beam"
export PROGNAME="erl"
export LD_LIBRARY_PATH="$ERTS_DIR/lib:$LD_LIBRARY_PATH"
export ERTS_LIB_DIR="$ERTS_DIR/../lib"
CONSOLIDATED_DIR="$ROOTDIR/lib/${REL_NAME}-${REL_VSN}/consolidated"

cd "$ROOTDIR"

# User can specify an sname without @hostname
# This will fail when creating remote shell
# So here we check for @ and add @hostname if missing
case $NAME in
    *@*)
        # Nothing to do
        ;;
    *)
        NAME=$NAME@$(gen_nodename)
        ;;
esac

# For Elixir runtime
export DISTILLERY_TASK="$1"

# Check the first argument for instructions
case "$1" in
    start|start_boot)

        # Make sure there is not already a node running
        #RES=`$NODETOOL ping`
        #if [ "$RES" = "pong" ]; then
        #    echo "Node is already running!"
        #    exit 1
        #fi
        # Save this for later.
        CMD=$1
        case "$1" in
            start)
                shift
                START_OPTION="console"
                HEART_OPTION="start"
                ;;
            start_boot)
                shift
                START_OPTION="console_boot"
                HEART_OPTION="start_boot"
                ;;
        esac
        ARGS="$@"
        RUN_PARAM="$@"

        _check_cookie
        _run_hooks_from_dir "$PRE_CONFIGURE_HOOKS"
        _run_hooks_from_dir "$PRE_START_HOOKS"

        # Set arguments for the heart command
        set -- "$SCRIPT_DIR/$REL_NAME" "$HEART_OPTION"
        [ "$RUN_PARAM" ] && set -- "$@" "$RUN_PARAM"

        # Export the HEART_COMMAND
        HEART_COMMAND="$RELEASE_ROOT_DIR/bin/$REL_NAME $CMD"
        export HEART_COMMAND

        mkdir -p "$PIPE_DIR"


        "$BINDIR/run_erl" -daemon "$PIPE_DIR" "$RUNNER_LOG_DIR" \
                          "$(_start_command)"

        _run_hooks_from_dir "$POST_START_HOOKS"
        ;;

    stop)
        _check_cookie
        _run_hooks_from_dir "$PRE_STOP_HOOKS"
        # Wait for the node to completely stop...
        PID="$(get_pid)"
        if ! nodetool "stop"; then
            exit 1
        fi
        while $(kill -s 0 "$PID" 2>/dev/null);
        do
            sleep 1
        done
        _run_hooks_from_dir "$POST_STOP_HOOKS"
        ;;

    restart)
        _check_cookie
        _run_hooks_from_dir "$PRE_CONFIGURE_HOOKS"
        _run_hooks_from_dir "$PRE_START_HOOKS"
        ## Restart the VM without exiting the process
        if ! nodetool "restart"; then
            exit 1
        fi
        ;;

    reboot)
        _check_cookie
        _run_hooks_from_dir "$PRE_CONFIGURE_HOOKS"
        _run_hooks_from_dir "$PRE_START_HOOKS"
        ## Restart the VM completely (uses heart to restart it)
        if ! nodetool "reboot"; then
            exit 1
        fi
        ;;

    pid)
        ## Get the VM's pid
        _check_cookie
        if ! get_pid; then
            exit 1
        fi
        ;;

    ping)
        _check_cookie
        ## See if the VM is alive
        if ! nodetool "ping"; then
            exit 1
        fi
        ;;

    pingpeer)
        PEERNAME=$2 nodetool "ping"
        exit_status=$?
        if [ "$exit_status" -ne 0 ]; then
            exit $exit_status
        fi
        ;;

    escript)
        _check_cookie
        ## Run an escript under the node's environment
        if ! escript $@; then
            exit 1
        fi
        ;;

    attach)
        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        shift
        exec "$BINDIR/to_erl" "$PIPE_DIR"
        ;;

    remote_console)
        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        shift
        _rem_sh
        ;;

    upgrade|downgrade|install)
        if [ -z "$2" ]; then
            echo "Missing package argument"
            echo "Usage: $REL_NAME $1 {package base name}"
            echo "NOTE {package base name} MUST NOT include the .tar.gz suffix"
            exit 1
        fi

        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        SOURCE_VERSION="$REL_VSN"
        TARGET_VERSION="$2"

        "$BINDIR/escript" "$ROOTDIR/bin/release_utils.escript" \
             "unpack_release" "$REL_NAME" "$NAME_TYPE"  "$NAME" "$COOKIE" "$TARGET_VERSION"

        # Update environment to reflect target version environment
        REL_VSN="$TARGET_VERSION"
        REL_DIR="$RELEASE_ROOT_DIR/releases/$TARGET_VERSION"

        # Prepare new configs
        _init_configs
        # We have to do some juggling to ensure the correct config is used by the upgrade handler
        # First, we detect if there was a failed upgrade, so we can start over
        if [ -f "$REL_DIR/sys.config.bak" ]; then
            mv "$REL_DIR/sys.config.bak" "$REL_DIR/sys.config"
        fi
        if [ -f "$REL_DIR/vm.args.bak" ]; then
            mv "$REL_DIR/vm.args.bak" "$REL_DIR/vm.args"
        fi
        # Then, backup the packaged configs
        cp "$REL_DIR/sys.config" "$REL_DIR/sys.config.bak"
        cp "$REL_DIR/vm.args" "$REL_DIR/vm.args.bak"
        # Then, substitute in the prepared configs
        cp "$SYS_CONFIG_PATH" "$REL_DIR/sys.config"
        cp "$VMARGS_PATH" "$REL_DIR/vm.args"
        # Make sure any pre-configuration hooks are run
        _run_hooks_from_dir "$PRE_CONFIGURE_HOOKS"
        # Run any pre-upgrade tasks
        _run_hooks_from_dir "$PRE_UPGRADE_HOOKS"

        "$BINDIR/escript" "$ROOTDIR/bin/release_utils.escript" \
             "install_release" "$REL_NAME" "$NAME_TYPE"  "$NAME" "$COOKIE" "$TARGET_VERSION"

        # We were successful, clean up the configs
        mv "$REL_DIR/sys.config.bak" "$REL_DIR/sys.config"
        mv "$REL_DIR/vm.args.bak" "$REL_DIR/vm.args"

        # Run any post-upgrade hooks
        _run_hooks_from_dir "$POST_UPGRADE_HOOKS"

        ;;
    unpack)
        if [ -z "$2" ]; then
            echo "Missing package argument"
            echo "Usage: $REL_NAME $1 {package base name}"
            echo "NOTE {package base name} MUST NOT include the .tar.gz suffix"
            exit 1
        fi

        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        exec "$BINDIR/escript" "$ROOTDIR/bin/release_utils.escript" \
             "unpack_release" "$REL_NAME" "$NAME_TYPE" "$NAME" "$COOKIE" "$2"
        ;;

    console|console_clean|console_boot)
        # .boot file typically just $REL_NAME (ie, the app name)
        # however, for debugging, sometimes start_clean.boot is useful.
        # For e.g. 'setup', one may even want to name another boot script.
        case "$1" in
            console)
                if [ -f "$REL_DIR/$REL_NAME.boot" ]; then
                  BOOTFILE="$REL_DIR/$REL_NAME"
                else
                  BOOTFILE="$REL_DIR/start"
                fi
                ;;
            console_clean)
                BOOTFILE="$ROOTDIR/bin/start_clean"
                __code_paths=$(_get_code_paths)
                EXTRA_CODE_PATHS=${__code_paths}
                ;;
            console_boot)
                shift
                BOOTFILE="$1"
                shift
                ;;
        esac
        # Setup beam-required vars
        EMU="beam"
        PROGNAME="${0#*/}"

        export EMU
        export PROGNAME

        # Store passed arguments since they will be erased by `set`
        ARGS="$@"

        _check_cookie

        # Start the VM, executing pre_start hook along
        # the way. We can't run the post_start hook because
        # the console will crash with no TTY attached
        _run_hooks_from_dir "$PRE_CONFIGURE_HOOKS"
        _run_hooks_from_dir "$PRE_START_HOOKS"

        # Build an array of arguments to pass to exec later on
        # Build it here because this command will be used for logging.
        set -- "$BINDIR/erlexec" \
            -boot "$BOOTFILE" \
            -boot_var ERTS_LIB_DIR "$ERTS_LIB_DIR" \
            -env ERL_LIBS "$REL_LIB_DIR" \
            -pa "$CONSOLIDATED_DIR" \
            ${EXTRA_CODE_PATHS} \
            -args_file "$VMARGS_PATH" \
            -config "$SYS_CONFIG_PATH" \
            -mode "$CODE_LOADING_MODE" \
            ${ERL_OPTS} \
            -user Elixir.IEx.CLI \
            -extra --no-halt +iex

        # Dump environment info for logging purposes
        if [ ! -z $VERBOSE ]; then
            echo "Exec: $@" -- ${1+$ARGS} ${EXTRA_OPTS}
            echo "Root: $ROOTDIR"

            # Log the startup
            echo "$RELEASE_ROOT_DIR"
        fi;

        logger -t "$REL_NAME[$$]" "Starting up"

        exec "$@" -- ${1+$ARGS} ${EXTRA_OPTS}
        ;;

    foreground)
        # start up the release in the foreground for use by runit
        # or other supervision services

        [ -f "$REL_DIR/$REL_NAME.boot" ] && BOOTFILE="$REL_NAME" || BOOTFILE=start
        FOREGROUNDOPTIONS="-noshell -noinput +Bd"

        # Setup beam-required vars
        EMU=beam
        PROGNAME="${0#*/}"

        export EMU
        export PROGNAME

        # Store passed arguments since they will be erased by `set`
        ARGS="$@"

        _check_cookie

        # Start the VM, executing pre and post start hooks
        _run_hooks_from_dir "$PRE_CONFIGURE_HOOKS"
        _run_hooks_from_dir "$PRE_START_HOOKS"

        # Build an array of arguments to pass to exec later on
        # Build it here because this command will be used for logging.
        set -- "$BINDIR/erlexec" $FOREGROUNDOPTIONS \
            -boot "$REL_DIR/$BOOTFILE" \
            -boot_var ERTS_LIB_DIR "$ERTS_LIB_DIR" \
            -env ERL_LIBS "$REL_LIB_DIR" \
            -pa "$CONSOLIDATED_DIR" \
            -args_file "$VMARGS_PATH" \
            -config "$SYS_CONFIG_PATH" \
            -mode "$CODE_LOADING_MODE" \
            ${ERL_OPTS} \
            -extra ${EXTRA_OPTS}

        # Dump environment info for logging purposes
        if [ ! -z $VERBOSE ]; then
            echo "Exec: $@" -- ${1+$ARGS}
            echo "Root: $ROOTDIR"
        fi;

        "$@" -- ${1+$ARGS} &
        __bg_pid=$!
        _run_hooks_from_dir "$POST_START_HOOKS"
        wait $__bg_pid
        ;;
    rpc)
        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        shift

        nodetool rpc $@
        ;;
    rpcterms)
        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        shift

        nodetool rpcterms $@
        ;;
    eval)
        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        shift
        nodetool "eval" $@
        ;;
    command)
        # Execute as command-line utility
        #
        # Like the escript command, this does not start the OTP application.
        # If your command depends on a running OTP application,
        # use
        #
        #     {:ok, _} = Application.ensure_all_started(:your_app)

        _check_cookie

        shift
        MODULE="$1"; shift
        FUNCTION="$1"; shift

        # Save extra arguments
        ARGS="$@"

        # Build arguments for erlexec
        __code_paths=$(_get_code_paths)
        set -- "$ERL_OPTS"
        [ "$SYS_CONFIG_PATH" ] && set -- "$@" -config "$SYS_CONFIG_PATH"
        set -- "$@" -boot_var ERTS_LIB_DIR "$ERTS_LIB_DIR"
        set -- "$@" -noshell
        set -- "$@" -boot start_clean
        set -- "$@" -pa "$CONSOLIDATED_DIR"
        set -- "$@" ${__code_paths}
        set -- "$@" -s "$MODULE" "$FUNCTION"


        $BINDIR/erlexec $@ -extra $ARGS
        exit "$?"
        ;;
    reload_config)
        # Reload the running system's configuration
        _check_cookie

        # Make sure a node IS running
        if ! nodetool "ping" > /dev/null; then
            echo "Node is not running!"
            exit 1
        fi

        _run_hooks_from_dir "$PRE_CONFIGURE_HOOKS"

        shift
        nodetool "reload_config" "$SYS_CONFIG_PATH"
        ;;
    describe)
        ## Print a summary of information about this release
        echo "$REL_NAME-$REL_VSN\n"
        echo "erts:       $ERTS_VSN"
        echo "path:       $REL_DIR"
        echo "sys.config: $SYS_CONFIG_PATH"
        echo "vm.args:    $VMARGS_PATH"
        echo "name:       $NAME"
        echo "cookie:     $COOKIE"
        echo "erl_opts:   ${ERL_OPTS:-none provided}"
        echo ""
        echo "hooks:"
        __has_hooks=0
        for hook in "$REL_DIR"/hooks/*.d/[0-9a-zA-Z]*.sh; do
            [ -f "$hook" ] || continue
            __has_hooks=1
            echo "$hook"
        done
        if [ $__has_hooks -eq 0 ]; then
            echo "No custom hooks found."
        fi
        echo ""
        echo "commands:"
        __has_commands=0
        for command in "$REL_DIR"/commands/*.sh; do
            [ -f "$command" ] || continue
            __has_commands=1
            echo "$command"
        done
        if [ $__has_commands -eq 0 ]; then
            echo "No custom commands found."
        fi
        exit 0
        ;;
    *)
        __command_path="$REL_DIR/commands/$1"
        if [ -f "$__command_path" ]; then
            _check_cookie
            . "$__command_path"
        else
            echo "Usage: $REL_NAME <task>"
            echo
            echo "Service Control"
            echo "======================="
            echo "start                          # start $REL_NAME as a daemon"
            echo "start_boot <file>              # start $REL_NAME as a daemon, but supply a custom .boot file"
            echo "foreground                     # start $REL_NAME in the foreground"
            echo "console                        # start $REL_NAME with a console attached"
            echo "console_clean                  # start a console with code paths set but no apps loaded/started"
            echo "console_boot <file>            # start $REL_NAME with a console attached, but supply a custom .boot file"
            echo "stop                           # stop the $REL_NAME daemon"
            echo "restart                        # restart the $REL_NAME daemon without shutting down the VM"
            echo "reboot                         # restart the $REL_NAME daemon"
            echo "reload_config                  # reload the current system's configuration from disk"
            echo
            echo "Upgrades"
            echo "======================="
            echo "upgrade <version>              # upgrade $REL_NAME to <version>"
            echo "downgrade <version>            # downgrade $REL_NAME to <version>"
            echo "install <version>              # install the $REL_NAME-<version> release, but do not upgrade to it"
            echo
            echo "Utilities"
            echo "======================="
            echo "attach                         # attach the current TTY to $REL_NAME's console"
            echo "remote_console                 # remote shell to $REL_NAME's console"
            echo "pid                            # get the pid of the running $REL_NAME instance"
            echo "ping                           # checks if $REL_NAME is running, pong is returned if successful"
            echo "pingpeer <peer>                # check if a peer node is running, pong is returned if successful"
            echo "escript <file>                 # execute an escript"
            echo "rpc <mod> <fun> [<args..>]     # execute an RPC call using the given MFA"
            echo "rpcterms <mod> <fun> [<expr>]  # execute an RPC call using the given Erlang expression for args"
            echo "eval <expr>                    # execute the given Erlang expression on the running node"
            echo "command <mod> <fun> [<args..>] # execute the given MFA"
            echo "describe                       # print useful information about the $REL_NAME release"
            echo
            echo "Custom Commands"
            echo "======================="
            __has_commands=0
            for command in "$REL_DIR"/commands/*.sh; do
                [ -f "$command" ] || continue
                __has_commands=1
                echo "$command"
            done
            if [ $__has_commands -eq 0 ]; then
                echo "No custom commands found."
            fi
            echo ""
            exit 1
        fi
        ;;
esac

exit 0
