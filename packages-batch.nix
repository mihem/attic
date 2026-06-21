let
  base = import ./packages.nix;

  parseInt = value:
    let
      parsed = builtins.fromJSON value;
    in if builtins.isInt parsed then parsed else throw "Expected integer, got ${value}";

  batchStartEnv = builtins.getEnv "BATCH_START";
  batchSizeEnv = builtins.getEnv "BATCH_SIZE";
  batchStart = if batchStartEnv == "" then 0 else parseInt batchStartEnv;
  batchSize = if batchSizeEnv == "" then 5000 else parseInt batchSizeEnv;

  allNames = builtins.attrNames base.rPackagesSet;
  total = builtins.length allNames;
  remaining = total - batchStart;
  batchLength = if remaining < 0 then 0 else if remaining < batchSize then remaining else batchSize;
  batchNames = builtins.genList (i: builtins.elemAt allNames (batchStart + i)) batchLength;

  batchPackages = builtins.listToAttrs (builtins.map (name: {
    inherit name;
    value = base.rPackagesSet.${name};
  }) batchNames);

  batchEnd = batchStart + batchLength;
in
  base // { inherit batchPackages batchStart batchEnd batchSize total; }
