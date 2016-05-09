#!/usr/bin/env bash
set -euf -o pipefail

# Set defaults, can be overriden with config_file (-f)
host="127.0.0.1"
port="3306"
user=
password=
excluded_dbs=   # must be comma-delimeted, eg "mysql,test,innodb"
included_dbs=
rotate=false    # true enables weekly/monthly rotation (copy)
do_monthly="01" # 01 to 31, 0 to disable monthly
do_weekly="6"   # day of week 1-7, 1 is Monday, 0 disables weekly
do_latest=true
bucket=
config_file=
region="us-east-1"
s3_prefix=
s3_daily_prefix="daily"
s3_weekly_prefix="weekly"
s3_monthly_prefix="monthly"
s3_latest_prefix="latest"
slave=false
rds_slave=false
dry_run=false
folder_per_db=false

# don't override these
repl_stopped=0

usage(){
  echo "Usage: $0 args
    -f PATH config file to use rather than specifying CLI arguments
    -u USER mysql username
    -p PWD  mysql password
    -H HOST mysql host (default: 127.0.0.1)
    -P PORT mysql port (default: 3306)
    -e DB   database to exclude, can be called multiple times,
            or called once with comma-delimited list (no spaces)
            will backup all databases except db(s) specified by this option
            (information_schema and performance_schema are _always_ excluded)
            cannot be used with -i
    -i DB   database to include, can be called multiple times
            or called once with comma-delimited list (no spaces)
            will only backup specified db(s), cannot be used with -e
    -s      this is a slave, will pause replication during backup
    -S      this is an RDS read-replica, will stop replication during backup
    -b BKT  S3 bucket name
    -d DIR  S3 prefix (will append daily/weekly/monthly if rotate enabled)
    -F      folder per DB - put each db in own S3 folder
    -R RGN  AWS Region (default: us-east-1)
    -r      enable weekly/monthly rotation, files will be copied to
            weekly/monthly S3 prefixes if this option is enabled.
            Note: UTC is used when calculating day of week and month
    -m INT  day of month to do monthly backup (01 to 31) (default: 01)
            use 0 to disable monthly backups (only relevant if -R specified)
    -w INT  day of week to do weekly backups (1-7, 1 is Monday) (default: 6)
            use 0 to disable weekly backups (only relevant if -R specified)
    -D      dry-run, explain only, will not pause replication or perform backups" >&2
  exit 1
}

die() {
  if [ -n "$1" ]; then echo "Error: $1" >&2; fi
  exit 1
}

mysql_cmd() {
  mysql --defaults-file="$cnf_file" --batch --skip-column-names -e "$1"
}

# calculate number of days in month; taken from automysqlbackup
# $1 = month, $2 = year
days_in_month() {
  m="$1"; y="$2"; a=$(( 30+(m+m/8)%2 ))
  (( m==2 )) && a=$((a-2))
  (( m==2 && y%4==0 && ( y<100 || y%100>0 || y%400==0) )) && a=$((a+1))
  printf '%d' $a
}

# Cleanup - ensure replication restarted and remove temp file
cleanup() {
  if [ "$slave" = true ] && [ "$repl_stopped" -eq "1" ]; then
    if [ "$dry_run" = true ]; then
      echo "execute 'START SLAVE SQL_THREAD'"
    else
      mysql_cmd 'START SLAVE SQL_THREAD'
    fi
  fi
  if [ "$rds_slave" = true ] && [ "$repl_stopped" -eq "1" ]; then
    if [ "$dry_run" = true ]; then
      echo "execute 'call mysql.rds_start_replication()'"
    else
      mysql_cmd 'call mysql.rds_start_replication()'
    fi
  fi
  rm -f "$cnf_file"
}

while getopts ":f:u:p:H:P:e:i:sSb:d:FR:rm:w:lDh" opt; do
  case $opt in
    f) config_file=$OPTARG;;
    u) user=$OPTARG;;
    p) password=$OPTARG;;
    H) host=$OPTARG;;
    P) port=$OPTARG;;
    e)
      if [ -n "$excluded_dbs" ]; then
        excluded_dbs="$excluded_dbs,$OPTARG"
      else
        excluded_dbs=$OPTARG
      fi
      ;;
    i)
      if [ -n "$included_dbs" ]; then
        included_dbs="$included_dbs,$OPTARG"
      else
        included_dbs=$OPTARG
      fi
      ;;
    s) slave=true;;
    S) rds_slave=true;;
    b) bucket=$OPTARG;;
    d) s3_prefix=$OPTARG;;
    F) folder_per_db=true;;
    R) region=$OPTARG;;
    r) rotate=true;;
    m) do_monthly=$OPTARG;;
    w) do_weekly=$OPTARG;;
    l) do_latest=false;;
    D) dry_run=true;;
    h) usage;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

if [ -n "$config_file" ]; then
  if [ ! -f "$config_file" ]; then die "config file '$config_file' does not exist"; fi
  if [ ! -r "$config_file" ]; then die "unable to access config file '$config_file'"; fi
  # shellcheck source=/dev/null
  source "$config_file"
fi

# basic input validation
if [ -z "$host" ]; then die "host is required"; fi
if [ -z "$user" ]; then die "username is required"; fi
if [ -z "$bucket" ]; then die "bucket is required"; fi
if [ "$slave" = true ] && [ "$rds_slave" = true ]; then
  die "slave option must be either slave or RDS slave, not both"
fi
if [ -n "$included_dbs" ] && [ -n "$excluded_dbs" ]; then
  die "specifying included *and* excluded databases is not supported"
fi
if [[ ! $do_weekly =~ ^[0-7]$ ]]; then die "invalid weekday"; fi
if [[ ! $do_monthly =~ ^(0|0[0-9]|[12][0-9]|3[01])$ ]]; then die "invalid month day: $do_monthly"; fi
if [ -n "$s3_prefix" ]; then bucket="$bucket/$s3_prefix"; fi

if [ "$dry_run" = true ]; then echo "Dry run enabled"; fi

# write temporary defaults-file
cnf_file=$(mktemp -t mysqldump-s3.XXXXXXXXXX)
cat << EOF > $cnf_file
[client]
user=$user
password=$password
host=$host
port=$port
EOF

# cleanup on any exit (restart replication, remove temp file, etc.)
trap cleanup ERR INT TERM EXIT

stamp=$(date -u +%Y%m%dT%H%MZ)  # UTC ISO-8601
s3_stamp_match='????????T????Z' # must be able to match stamp above
date_day_of_week=$(date -u +%u)
date_day_of_month=$(date -u +%d)
date_year=$(date -u +%Y)
date_month=$(date -u +%m)
last_day_of_month=$(days_in_month "$date_month" "$date_year")

# get array of databases to backup
if [ -n "$included_dbs" ]; then
  OIFS=$IFS
  IFS=','
  read -r -a databases <<< "$included_dbs"
  IFS=$OIFS
  all_dbs=($(mysql_cmd 'SHOW DATABASES'))
  for db in "${databases[@]}"; do
    if [[ ! " ${all_dbs[@]} " =~ " ${db} " ]]; then
      die "database $db not found"
    fi
  done
else
  skip_dbs="information_schema,performance_schema"
  if [ -n "$excluded_dbs" ]; then skip_dbs="$skip_dbs|$excluded_dbs"; fi
  # replace comma with | and add $ anchor to end of each db name for grep match
  databases=($(mysql_cmd 'SHOW DATABASES' | grep -Ev "(${skip_dbs//,/$|}$)"))
fi

# pause replication
if [ "$slave" = true ]; then
  if [ "$dry_run" = true ]; then
    echo "execute 'STOP SLAVE SQL_THREAD'"
  else
    mysql_cmd 'STOP SLAVE SQL_THREAD'
  fi
  repl_stopped=1
fi

if [ "$rds_slave" = true ]; then
  if [ "$dry_run" = true ]; then
    echo "execute 'call mysql.rds_stop_replication()'"
  else
    mysql_cmd 'call mysql.rds_stop_replication()'
  fi
  repl_stopped=1
fi

# do the needful
for db in "${databases[@]}"; do
  fname="${db}_${stamp}.sql.gz"
  if [ "$folder_per_db" = true ]; then
    db_fname="$db/$fname"
  else
    db_fname="$fname"
  fi
  if [ "$rotate" = true ]; then
    s3_path="s3://$bucket/$s3_daily_prefix/$db_fname"
  else
    s3_path="s3://$bucket/$db_fname"
  fi


  echo "Dumping $db to $s3_path"
  if [ "$dry_run" != true ]; then
    mysqldump --defaults-file="$cnf_file" --single-transaction "$db" | gzip | aws s3 cp - "$s3_path" --region "$region"
  fi

  if [ "$rotate" = true ]; then
    # weekly
    if (( do_weekly == date_day_of_week )); then
      s3_weekly_path="s3://$bucket/$s3_weekly_prefix/$db_fname"
      if [ "$dry_run" = true ]; then
        echo "aws s3 cp \"$s3_path\" \"$s3_weekly_path\" --region \"$region\""
      else
        aws s3 cp "$s3_path" "$s3_weekly_path" --region "$region"
      fi
    fi

    # monthly
    if (( date_day_of_month == do_monthly || date_day_of_month == last_day_of_month && last_day_of_month < do_monthly )); then
      s3_monthly_path="s3://$bucket/$s3_monthly_prefix/$db_fname"
      if [ "$dry_run" = true ]; then
        echo "aws s3 cp \"$s3_path\" \"$s3_monthly_path\" --region \"$region\""
      else
        aws s3 cp "$s3_path" "$s3_monthly_path" --region "$region"
      fi
    fi

    # latest
    if [ "$do_latest" = true ]; then
      if [ "$dry_run" = true ]; then
        echo "aws s3 cp $s3_path s3://$bucket/$s3_latest_prefix/$fname"
        echo "aws s3 rm s3://$bucket/$s3_latest_prefix/ --recursive --exclude=\"*\" --include=\"${db}_${s3_stamp_match}.sql.gz\" --exclude=\"$fname\""
      else
        aws s3 cp "$s3_path" "s3://$bucket/$s3_latest_prefix/$fname"
        # delete all files like "db_name_YYYYMMDDTHHMMZ.sql.gz" except for the one just copied
        aws s3 rm "s3://$bucket/$s3_latest_prefix/" --recursive --exclude="*" --include="${db}_${s3_stamp_match}.sql.gz" --exclude="$fname"
      fi
    fi
  fi
done

echo "Done. Completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
