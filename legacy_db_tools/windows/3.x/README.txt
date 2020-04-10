
  AppDynamics Windows On-Prem Controller Embedded MySQL Database Recovery Tools

Recommended Usage:
* stop controller (leave database up)
* scan
* dump
* stop database
* fresh install
* stop controller (leave database up)
* load
* start controller


Build:
$ mvn clean package


NOTE:
  scan => scan-tables.cmd
  dump => dump-metadata.cmd      (only metadata, no historical data, dumps to single file)
          dump-all.cmd           (all metadata + historical data, partitioned tables get one dump file each)
          dump-all-by-partitions (all metadata + historical data, partitioned tables get one dump file for each partition)
  load => load-metadata.cmd      (only loads single metadata file)
          load-all               (loads metadata + historical data)

** DO NOT mix dump-all and dump-all-by-partition

Dumps/Loads can be parallelized by starting additional dump|load script instances.

Example session:
> start "scan" cmd /k scan-tables
... wait
> start "dump-metadata" cmd /k dump-metadata
... wait
> start "dump-part1" cmd /k dump-all
> start "dump-part2" cmd /k dump-all
> start "dump-part3" cmd /k dump-all
...
OR
> start "dump-by-part1" cmd /k dump-all-by-partitions
> start "dump-by-part2" cmd /k dump-all-by-partitions
> start "dump-by-part3" cmd /k dump-all-by-partitions
...
