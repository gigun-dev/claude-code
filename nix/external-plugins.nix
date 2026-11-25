# Pinned external plugins, built once for every agent host (docs/adr).
#
# npm plugins (nix/npm-sources.json) are unpacked once to $out/lib/<name>, and
# scripts/build_external_plugin.py adds what each host reads:
#   $out/bin/<server>-mcp             the one MCP command every host starts
#                                     (pinned node by absolute path, mcpEnv set)
#   $out/share/agent-plugins/<name>/  Agent Plugins 1.0 plugin.json + mcp.json,
#                                     .claude-plugin/plugin.json, skills/
#   $out/share/agy-plugins/<name>/    agy manifest, mcp_config.json, skills/ split
#                                     under agy's 24 KB body limit
# Git plugins (gitNames, pinned in the marketplace) only get the agy variant, as
# before. The consumer (dotfiles) places these through passthru, not by paths
# it spells out itself; see passthru below.
#
# mcpEnv adds environment per plugin and MCP server, for values that belong to
# the consumer (for REA, the analysis engine):
#   external-plugins.override {
#     mcpEnv.rea.rea = { GHIDRA_INSTALL_DIR = "..."; JAVA_HOME = "..."; };
#   }
{
  lib,
  stdenvNoCC,
  fetchurl,
  python3,
  runtimeShell,
  nodejs_26,
  # Why not the consumer's nodejs: rea-agents 6.9.0 requires >=24.22.1 on the
  # 24 line and its launcher exits on older ones, and a dotfiles nixpkgs pinned
  # on 2026-11-13 still had 24.21.0. The install check starts the server, so a
  # runtime it refuses fails the build instead of the agent session.
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
      ../scripts/build_external_plugin.py
      ../scripts/generate_manifests.py
    ];
  };
  unknown = lib.subtractLists (lib.attrNames sources ++ lib.attrNames gitSources) (lib.attrNames mcpEnv);
  # Codex reads every skill from one flat ~/.agents/skills, and bin/ is shared.
  allSkills = lib.concatMap (s: s.skills) (lib.attrValues sources);
  allServers = lib.concatMap (s: s.mcpServers) (lib.attrValues sources);
  duplicates = xs: lib.unique (builtins.filter (x: lib.count (y: y == x) xs > 1) xs);
  clash = lib.attrNames (lib.intersectAttrs sources gitSources);
  install = name: source: ''
    mkdir -p "$out/lib/${name}"
    tar -xzf ${
      fetchurl {
        inherit (source) url hash;
        name = "${source.package}-${source.version}.tgz";
      }
    } -C "$out/lib/${name}" --strip-components=1 --no-same-owner
    python3 ${scripts}/build_external_plugin.py "$out" ${name} \
      --node ${lib.getExe mcpNode} --shell ${runtimeShell} \
      --env ${lib.escapeShellArg (builtins.toJSON (mcpEnv.${name} or { }))} \
      --servers ${lib.escapeShellArg (builtins.toJSON source.mcpServers)} \
      --skills ${lib.escapeShellArg (builtins.toJSON source.skills)}
  '';
  installGit = name: source:
    let
      checkout = builtins.fetchGit { inherit (source) url; rev = source.sha; };
      subdir = if source.source == "git-subdir" then "/${source.path}" else "";
      dir = "$out/share/agy-plugins/${name}";
    in ''
      mkdir -p "${dir}"
      cp -R ${checkout}${subdir}/. "${dir}/"
      chmod -R u+w "${dir}"
      if [ -f "${dir}/SKILL.md" ]; then
        mkdir -p "${dir}/skills/${name}"
        cp -R ${checkout}${subdir}/. "${dir}/skills/${name}/"
        chmod -R u+w "${dir}/skills/${name}"
      fi
      python3 ${scripts}/agy_wrap_plugin.py "${dir}" \
        --node ${lib.getExe mcpNode} \
        --env ${lib.escapeShellArg (builtins.toJSON (mcpEnv.${name} or { }))}
    '';
in
assert lib.assertMsg (unknown == [ ]) "external-plugins: mcpEnv names unknown plugins: ${toString unknown}";
assert lib.assertMsg (builtins.length gitEntries == builtins.length gitNames) "external-plugins: missing Git marketplace entry";
assert lib.assertMsg (clash == [ ]) "external-plugins: both an npm and a Git plugin named ${toString clash}";
assert lib.assertMsg (duplicates allSkills == [ ]) "external-plugins: skill names used by two plugins: ${toString (duplicates allSkills)}";
assert lib.assertMsg (duplicates allServers == [ ]) "external-plugins: MCP server names used by two plugins: ${toString (duplicates allServers)}";
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "external-plugins";
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

  # Start every MCP command the way a host does and require tools/list; the
  # npm agy variants point at the same bin/ commands, so only Git plugins with
  # their own mcp_config.json are started a second time.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR"
    cd "$TMPDIR"
    if [ -d "$out/bin" ]; then
      python3 ${scripts}/build_external_plugin.py --smoke "$out"/bin/*
    fi
    ${lib.concatMapStrings (name: ''
      if [ -f "$out/share/agy-plugins/${name}/mcp_config.json" ]; then
        python3 ${scripts}/agy_wrap_plugin.py "$out/share/agy-plugins/${name}" --smoke
      fi
    '') (lib.attrNames gitSources)}
    runHook postInstallCheck
  '';

  # What the consumer places, as store paths of this build (so an override
  # with mcpEnv yields paths into the overridden output):
  #   plugins.<name>.dir          shared plugin dir; Claude: ~/.claude/skills/<name>
  #   plugins.<name>.mcpServers   <server> = command; Codex: [mcp_servers.<server>]
  #   plugins.<name>.skills       <skill> = dir; Codex: ~/.agents/skills/<skill>
  #   agy.dir / agy.names         one ~/.gemini/config/plugins.json entry
  passthru =
    let
      out = finalAttrs.finalPackage;
      shared = name: "${out}/share/agent-plugins/${name}";
    in
    {
      inherit sources gitSources;
      plugins = lib.mapAttrs (name: s: {
        dir = shared name;
        mcpServers = lib.genAttrs s.mcpServers (server: "${out}/bin/${server}-mcp");
        skills = lib.genAttrs s.skills (skill: "${shared name}/skills/${skill}");
      }) sources;
      agy = {
        dir = "${out}/share/agy-plugins";
        names = lib.attrNames sources ++ lib.attrNames gitSources;
      };
    };

  meta = {
    description = "Pinned external agent plugins built once for Claude Code, Codex and agy";
    platforms = lib.platforms.unix;
  };
})
