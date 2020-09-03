{
  description = "Build npm and yarn packages";

  outputs = { self }: {
    overlay = final: prev: {
      inherit (final.callPackage ./. { }) mkNodeModules buildNpmPackage buildYarnPackage;
    };
  };
}
