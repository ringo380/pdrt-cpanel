#!/bin/bash
#
# Only argument should be the database name

set -e
mysql_user="root"
mysql_host="localhost"
mysql_db=$1
top_dir="`pwd`"

if [[ ! -f /root/.my.cnf ]]; then
	echo "/root/.my.cnf not found - please provide MySQL root password:"
	$mysql_password = read mysql_password
	MYSQL="mysql -u root -p$mysql_password -h$mysql_host"
else
	mysql_password="`grep pass /root/.my.cnf | cut -d= -f2 | sed -e 's/^"//'  -e 's/"$//'`"
	MYSQL="mysql"
fi

# Check that the script is run from source directory
if ! test -f "$top_dir/page_parser.c"
then
        echo "Script $0 must be run from a directory with Percona InnoDB Recovery Tool source code"
        exit 1
fi

# Check for existing work directory, create new if needed
if [ ! -f /root/.work_dir ];
	then 
	work_dir="/tmp/recovery_$RANDOM"
	echo "$work_dir" > /root/.work_dir
	echo -n "No current work directory exists. Initializing working directory at $work_dir... "
	mkdir "$work_dir"
	cd "$work_dir"
	trap "if [ $? -ne 0 ] ; then rm -r \"$work_dir\"; fi" EXIT
	echo "OK"
else
	echo "Found existing /root/.work_dir file, checking for valid path... "
	work_dir=`cat /root/.work_dir`
	if test -d "$work_dir"; 
		then
        echo "Using $work_dir... "
		cd "$work_dir"
		echo "OK"
	else 
		echo "/root/.work_dir exists, but does not contain a valid path."
		exit 1
	fi
fi

#echo -n "Testing MySQL connection... "
#if test -z "$mysql_password"
#then
#        MYSQL="mysql -u$mysql_user -h $mysql_host"
#else
#        MYSQL="mysql -u$mysql_user -p$mysql_password -h $mysql_host"
#fi

echo "Retrieving existing table data... "
$MYSQL -e "SELECT COUNT(*) FROM user" mysql >/dev/null
has_innodb=`$MYSQL -e "SHOW ENGINES"| grep InnoDB| grep -e "YES" -e "DEFAULT"`
if test -z "$has_innodb"
then
        echo "InnoDB is not enabled on this MySQL server"
        exit 1
fi
echo "OK"

echo -n "Building InnoDB dictionaries parsers... "
cd "$top_dir"
make dict_parsers > "$work_dir/make.log" 2>&1
cp page_parser bin
cd "$work_dir"
echo "OK"

# Get datadir & table names
tables=`$MYSQL -NB -e "SELECT TABLE_NAME FROM TABLES WHERE TABLE_SCHEMA='$mysql_db' and ENGINE='InnoDB'" information_schema`
datadir="`$MYSQL  -e "SHOW VARIABLES LIKE 'datadir'" -NB | awk '{ $1 = ""; print $0}'| sed 's/^ //'`"
innodb_file_per_table=`$MYSQL  -e "SHOW VARIABLES LIKE 'innodb_file_per_table'" -NB | awk '{ print $2}'`
innodb_data_file_path=`$MYSQL  -e "SHOW VARIABLES LIKE 'innodb_data_file_path'" -NB | awk '{ $1 = ""; print $0}'| sed 's/^ //'`

echo "Splitting InnoDB tablespace into pages... "
old_IFS="$IFS"
IFS=";"
for ibdata in $innodb_data_file_path
do
	ibdata_file=`echo $ibdata| awk -F: '{print $1}'`.recovery
	echo "ibdata_file is $ibdata_file"
	"$top_dir"/bin/page_parser -f "$datadir/$ibdata_file"
	mv pages-* "pages-$ibdata_file"
done
IFS=$old_IFS
if [ $innodb_file_per_table == "ON" ]
then
	for t in $tables
	do
		"$top_dir"/bin/page_parser -f "$datadir/$mysql_db/$t.ibd"
		mv pages-[0-9]* "pages-$t"
	done
fi
echo "OK"

echo -n "Recovering InnoDB dictionary... "
old_IFS="$IFS"
IFS=";"
for ibdata in $innodb_data_file_path
do
	ibdata_file=`echo $ibdata| awk -F: '{print $1}'`.recovery
	dir="pages-$ibdata_file"/FIL_PAGE_INDEX/0-1
	mkdir -p "$work_dir/dumps/${mysql_db}"
	if test -d "$dir"
	then
		"$top_dir"/bin/constraints_parser.SYS_TABLES -4Uf "$dir" -p "${mysql_db}" >> "dumps/${mysql_db}/SYS_TABLES" 2>SYS_TABLES.sql
	fi
	dir="pages-$ibdata_file"/FIL_PAGE_INDEX/0-3
	if test -d "$dir"
	then
		"$top_dir"/bin/constraints_parser.SYS_INDEXES -4Uf "$dir" -p "${mysql_db}" >> "dumps/${mysql_db}/SYS_INDEXES" 2>SYS_INDEXES.sql
	fi

done
IFS=$old_IFS

cd "$top_dir"
ln -fs table_defs.h.SYS_TABLES include/table_defs.h
echo "DONE"
