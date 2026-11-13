# Pinned external npm and Git plugins as Antigravity CLI (agy) plugins.
#
# The output is a directory of plugins, $out/<name>/, for one entry in
# ~/.gemini/config/plugins.json: { path = "${pkg}"; include_only = [ ... ]; }.
# Each plugin is the upstream npm tarball as published, plus what
# scripts/agy_wrap_plugin.py adds: the agy manifest, mcp_config.json with an
# absolute node, and SKILL.md bodies split under agy's 24 KB load limit.
#
# mcpEnv adds environment per plugin and MCP server, for values that belong to
# the consumer (for REA, the analysis engine):
#   agy-external-plugins.override {
#     mcpEnv.rea.rea = { GHIDRA_INSTALL_DIR = "..."; JAVA_HOME = "..."; };
#   }
{
  lib,
  stdenvNoCC,
  fetchurl,
  python3,
  nodejs_26,
  # Why not the consumer's nodejs: rea-agents 6.9.0 requires >=24.22.1 on the
  # 24 line and its launcher exits on older ones, and a dotfiles nixpkgs pinned
  # on 2026-11-13 still had 24.21.0. The install check starts the server, so a
  # runtime it refuses fails the build instead of the agy session.
  mcpNode ? nodejs_26,
  mcpEnv ? { },
}:
let
  sources = lib.filterAttrs (name: _: !lib.hasPrefix "$" name) (lib.importJSON ./npm-sources.json);
  marketplace = lib.importJSON ../.claude-plugin/marketplace.json;
  # Git plugins need an agy-compatible layout; add names here after checking it.
  gitNames = [ "visual-explainer" ];
  gitEntries = builtins.filter (p: builtins.elem p.name gitNames) marketplace.plugins;
  gitSources = builtins.listToAttrs (map (p: {
    inherit (p) name;
    value = p.source;
  }) gitEntries);
  scripts = lib.fileset.toSource {
    root = ../scripts;
    fileset = lib.fileset.unions [
      ../scripts/agy_wrap_plugin.py
      ../scripts/generate_manifests.py
    ];
  };
  unknown = lib.subtractLists (lib.attrNames sources ++ lib.attrNames gitSources) (lib.attrNames mcpEnv);
  install = name: source: ''
    mkdir -p "$out/${name}"
    tar -xzf ${
      fetchurl {
        inherit (source) url hash;
        name = "${source.package}-${source.version}.tgz";
      }
    } -C "$out/${name}" --strip-components=1 --no-same-owner
    python3 ${scripts}/agy_wrap_plugin.py "$out/${name}" \
      --node ${lib.getExe mcpNode} \
      --env ${lib.escapeShellArg (builtins.toJSON (mcpEnv.${name} or { }))}
  '';
  installGit = name: source:
    let
      checkout = builtins.fetchGit { inherit (source) url; rev = source.sha; };
      subdir = if source.source == "git-subdir" then "/${source.path}" else "";
    in ''
      mkdir -p "$out/${name}"
      cp -R ${checkout}${subdir}/. "$out/${name}/"
      chmod -R u+w "$out/${name}"
      if [ -f "$out/${name}/SKILL.md" ]; then
        mkdir -p "$out/${name}/skills/${name}"
        cp -R ${checkout}${subdir}/. "$out/${name}/skills/${name}/"
        chmod -R u+w "$out/${name}/skills/${name}"
      fi
      python3 ${scripts}/agy_wrap_plugin.py "$out/${name}" \
        --node ${lib.getExe mcpNode} \
        --env ${lib.escapeShellArg (builtins.toJSON (mcpEnv.${name} or { }))}
    '';
in
assert lib.assertMsg (unknown == [ ]) "agy-external-plugins: mcpEnv names unknown plugins: ${toString unknown}";
assert lib.assertMsg (builtins.length gitEntries == builtins.length gitNames) "agy-external-plugins: missing Git marketplace entry";
stdenvNoCC.mkDerivation {
  pname = "agy-external-plugins";
  version = lib.concatStringsSep "+" (
    lib.mapAttrsToList (name: s: "${name}-${s.version}") sources
    ++ lib.mapAttrsToList (name: s: "${name}-${builtins.substring 0 12 s.sha}") gitSources
  );

  dontUnpack = true;
  # Why not the default fixup: it rewrites shebangs and strips binaries across
  # the upstream tree (native/ included), so the plugin would no longer be the
  # package as published. Node runs the plugin by absolute path; nothing here
  # needs patching.
  dontFixup = true;
  nativeBuildInputs = [ python3 ];

  installPhase = ''
    runHook preInstall
    ${lib.concatStrings (lib.mapAttrsToList install sources)}
    ${lib.concatStrings (lib.mapAttrsToList installGit gitSources)}
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR"
    for plugin in "$out"/*/; do
      [ -f "$plugin/mcp_config.json" ] && python3 ${scripts}/agy_wrap_plugin.py "$plugin" --smoke
    done
    runHook postInstallCheck
  '';

  passthru = { inherit sources gitSources; };

  meta = {
    description = "Pinned external plugins wrapped for the Antigravity CLI (agy)";
    platforms = lib.platforms.unix;
  };
}
