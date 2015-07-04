#!/bin/bash

function create_patch() {
  source_dir_path=$1
  patch_file_path=$2
  mkdir -p $patch_file_path

  original_files_loc=$source_dir_path/original
  if [ ! -d $original_files_loc ]; then
    echo "ERROR: $source_dir_path doesn't contain directories in expected structure."
    exit 1
  fi

  cd $original_files_loc
  list_of_dirs=$(ls )
  for dir_name in $list_of_dirs; do
    echo "Creating patch for $original_files_loc/$dir_name"
    diff -u10 --text -r -N $dir_name ../resources/$dir_name > $patch_file_path/$dir_name.patch
    echo "Patch created at $patch_file_path/$dir_name.patch"
  done
  cd -
}

function apply_patch() {
  target_dir=$1
  patch_file_path=$2
  strip_num=$3

  echo "Following files will be patched: "
  echo "***********"
  lsdiff --strip=$strip_num $patch_file_path
  echo "***********"

  patch --dry-run --silent --strip=$strip_num -N -d $target_dir -i $patch_file_path
  if [ $? -eq 0 ]; then
    patch --strip=$strip_num -N -b -V numbered -d $target_dir -i $patch_file_path
  else
    echo "Not able to apply patches."
  fi
}

function merge_patch() {
  target_dir=$1
  patch_file_path=$2
  strip_num=$3

  echo "Following files will be patched: "
  echo "***********"
  lsdiff --strip=$strip_num $patch_file_path
  echo "***********"

  patch --dry-run --silent --strip=$strip_num -N --merge -d $target_dir -i $patch_file_path
  if [ $? -eq 0 ]; then
    patch --strip=$strip_num -N -b -V numbered --merge -d $target_dir -i $patch_file_path
  else
    echo "Not able to apply patches."
  fi
}

function revert_patch() {
  target_dir=$1
  patch_file_path=$2
  strip_num=$3

  echo "Patches on following files will be reverted: "
  echo "***********"
  lsdiff --strip=$strip_num $patch_file_path
  echo "***********"

  patch --dry-run --silent --strip=$strip_num -R -d $target_dir -i $patch_file_path
  if [ $? -eq 0 ]; then
    patch --strip=$strip_num -R -b -V numbered -d $target_dir -i $patch_file_path
  else
    echo "Not able to apply patches."
  fi
}

function revert_using_backup() {
  target_dir=$1
  patch_file_path=$2
  strip_num=$3

  echo "Patches on following files will be reverted: "
  echo "***********"
  lsdiff --strip=$strip_num $patch_file_path
  echo "***********"

  backup_files=$(lsdiff --strip=$strip_num $patch_file_path)

  for file in $backup_files; do
    if [ -f $target_dir/$file.~1~ ]; then
      cp $target_dir/$file.~1~ $target_dir/$file
      echo "$target_dir/$file file has been replaced with backup file $target_dir/$file.~1~"
    else
      echo "ERROR: Backup for $target_dir/$file doesn't exists."
    fi
  done

}

function help() {
  echo "Usage: patchutil FUNC_NAME [ARG1]...[ARGN]"
  echo ""
  echo "This utility provides different utility methods related to patching source code."
  echo "Following functions are supported by this utility"
  echo ""
  echo "help -- Print complete help"
  echo "create_patch ORIG_DIR_PATH MODIFIED_DIR_PATH PATCH_FILE_PATH --- Generates patch file containing patches for all modified files"
  echo "apply_patch TARGET_DIR PATCH_FILE --- Apply patches on the files in given directory"
  echo "merge_patch TARGET_DIR PATCH_FILE --- Merge patches on the files in given directory"
  echo "revert_patch TARGET_DIR PATCH_FILE --- Revert patches on the files in given directory"
  echo "revert_using_backup TARGET_DIR PATCH_FILE --- Revert patches on the files in given directory using backup files"
}

if [[ $# -lt 1 || $1 = "help" ]]; then
  help
elif [[ $1 = "create_patch" || $1 = "apply_patch" || $1 = "merge_patch" || $1 = "revert_patch" || $1 = "revert_using_backup" ]]; then
  $@
else
  help
fi
