Convert monX outputs to CSV as follows:

perl iostat_reformat.pl -c < <(cat *iostat*.txt)

bash vmstat_to_csv.sh < <(cat *vmstat*.txt)

# dbtest is not currently currently

perl dbvars_to_csv.pl < <(cat *dbvars*.txt)

bash fdcount_to_csv.sh < <(cat *fdcount*.txt)

perl memsize_to_csv.pl < <(cat *memsize*.txt)

perl conxcount_to_csv.pl < <(cat *conx*.txt)

perl numabuddyrefs_to_csv.pl < <(cat *numabu*.txt)

# numastat is not currently converted

perl ../../slowlogmetric.pl -c < <(cat *slowlog*.txt)

# statics is not currently converted

perl gfpools_to_csv.pl < <(cat *gfpool*.txt)


