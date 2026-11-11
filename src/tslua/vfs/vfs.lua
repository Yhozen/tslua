local vfs = require("tslua.vfs")

-- FS is a file system abstraction (a Go interface). Implementations provide:
--
--   UseCaseSensitiveFileNames() -> bool
--       returns true if the file system is case-sensitive.
--   FileExists(path) -> bool
--   ReadFile(path) -> contents, ok
--       reads the file specified by path and returns the content.
--       If the file fails to be read, ok will be false.
--   WriteFile(path, data) -> err
--   AppendFile(path, data) -> err
--       appends data to the file at path, creating it if it does not exist.
--   Remove(path) -> err
--       removes `path` and all its contents. Will return the first error it encounters.
--   Chtimes(path, aTime, mTime) -> err
--   DirectoryExists(path) -> bool
--   GetAccessibleEntries(path) -> Entries
--       returns the files/directories in the specified directory.
--       If any entry is a symlink, it will be followed.
--   Stat(path) -> FileInfo or nil
--   WalkDir(root, walkFn) -> err
--       walks the file tree rooted at root, calling walkFn(path, dirEntry, err) for each file or
--       directory in the tree. Same behavior as fs.WalkDir, but with paths as strings.
--   Realpath(path) -> string
--       returns the "real path" of the specified path, following symlinks and correcting
--       filename casing.
--
-- Errors are nil or vfs.iofs error objects (see iofs.lua).

-- Entries is { files = {...}, directories = {...}, symlinks = set or nil }.
-- symlinks contains the names of entries in files or directories that were originally symbolic
-- links (or reparse points) on disk. The names are the same as those in files/directories (i.e.,
-- the link name, not the target). nil means symlink information is not available and the entries
-- may need to be re-checked for symlinks.
function vfs.NewEntries(files, directories, symlinks)
    return { files = files, directories = directories, symlinks = symlinks }
end

vfs.ErrInvalid = vfs.iofs.ErrInvalid       -- "invalid argument"
vfs.ErrPermission = vfs.iofs.ErrPermission -- "permission denied"
vfs.ErrExist = vfs.iofs.ErrExist           -- "file already exists"
vfs.ErrNotExist = vfs.iofs.ErrNotExist     -- "file does not exist"
vfs.ErrClosed = vfs.iofs.ErrClosed         -- "file already closed"

-- SkipAll is fs.SkipAll.
vfs.SkipAll = vfs.iofs.SkipAll

-- SkipDir is fs.SkipDir.
vfs.SkipDir = vfs.iofs.SkipDir

return vfs
