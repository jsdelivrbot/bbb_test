use Mix.Releases.Config,
    # This sets the default release built by `mix release`
    default_release: :default,
    # This sets the default environment used by `mix release`
    default_environment: :dev

# For a full list of config options for both releases
# and environments, visit https://hexdocs.pm/distillery/configuration.html


# You may define one or more environments in this file,
# an environment's settings will override those of a release
# when building in that environment, this combination of release
# and environment configuration is called a profile

environment :dev do
  set cookie: :"nhn7nHDd~fIFCUKnSxQ>f|?_1j=tnHTTGN5.UKdb[}n2]|17~M`K;w2t}5J.QP7~"
end

environment :prod do
  set cookie: :"nhn7nHDd~fIFCUKnSxQ>f|?_1j=tnHTTGN5.UKdb[}n2]|17~M`K;w2t}5J.QP7~"
end

# You may define one or more releases in this file.
# If you have not set a default release, or selected one
# when running `mix release`, the first release in the file
# will be used by default

release :bbb_test do
  set version: current_version(:bbb_test)
  if System.get_env("NERVES_SYSTEM") do
    set dev_mode: false
    set include_src: false
    set include_erts: System.get_env("ERL_LIB_DIR")
    set include_system_libs: System.get_env("ERL_SYSTEM_LIB_DIR")
    set vm_args: "rel/vm.args"
  end
end

