
# This script provides various methods to create a tree-like structure of directories and files in a shell environment.
#!/bin/bash
ls -R | grep ":$" | sed -e 's/:$//' -e 's/[^-][^\/]*\//--/g' -e 's/^/   /' -e 's/-/|/'

# Using find to create a tree-like structure
find . -print | sed -e 's;[^/]*/;|____;g;s;____|; |;g'

# Using ls to create a tree-like structure
ls -R | awk '/:$/{print $1; next} {print "├── " $0}'

# Using find to create a tree-like structure
find . -type d | sed 's/[^-][^\/]*\//  |/g' | sed 's/|\([^ ]\)/├──\1/'

# Using find to create a tree-like structure with indentation
find . | sed -e "s/[^-][^\/]*\//  |/g" -e "s/|\([^ ]\)/├──\1/"

# Using find to create a tree-like structure with indentation and file names
find . -printf '%P\n' | sed 's|[^/]*/|- |g'

# Using tree command to create a tree-like structure
tree_replica() {
    find ${1:-.} -print | sed -e 's;[^/]*/;|____;g;s;____|; |;g'
}