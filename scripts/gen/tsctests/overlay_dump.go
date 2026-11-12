// Overlay file added to internal/execute/tsctests by gen.mjs (go test -overlay); not built on its own.

package tsctests

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"
)

var recordNowTime = time.Date(3000, 1, 1, 0, 0, 0, 0, time.UTC)

type recorder struct {
	ops [][]any
}

const readSentinelPrefix = "\x00READ\x00"

func encArg(a string) any {
	if strings.HasPrefix(a, readSentinelPrefix) {
		return map[string]string{"read": strings.TrimPrefix(a, readSentinelPrefix)}
	}
	if strings.Contains(a, readSentinelPrefix) {
		panic("sentinel used in expression: " + a)
	}
	return a
}

func (r *recorder) call(name string, args ...string) string {
	op := []any{name}
	for _, a := range args {
		op = append(op, encArg(a))
	}
	r.ops = append(r.ops, op)
	if name == "readFileNoError" {
		return readSentinelPrefix + args[0]
	}
	return ""
}

type recordingFs struct {
	*testFs
	r *recorder
}

func (f *recordingFs) Chtimes(path string, aTime time.Time, mTime time.Time) error {
	if !aTime.IsZero() || !mTime.Equal(recordNowTime) {
		panic("unsupported Chtimes in edit")
	}
	f.r.ops = append(f.r.ops, []any{"FS().Chtimes", path, map[string]bool{"zeroTime": true}, map[string]bool{"now": true}})
	return nil
}

func (f *recordingFs) WriteFile(path string, data string) error {
	panic("unsupported FS().WriteFile in edit")
}

func (f *recordingFs) Remove(path string) error {
	panic("unsupported FS().Remove in edit")
}

type dumpFile struct {
	Path    string `json:"path"`
	Symlink bool   `json:"symlink,omitempty"`
	Data    string `json:"data"`
}

type dumpEdit struct {
	Caption                      string    `json:"caption"`
	CommandLineArgs              *[]string `json:"commandLineArgs,omitempty"`
	ExpectedDiff                 string    `json:"expectedDiff,omitempty"`
	Ops                          *[][]any  `json:"ops,omitempty"`
	OpsForIncrementalCorrectness *[][]any  `json:"opsForIncrementalCorrectness,omitempty"`
	NoChange                     bool      `json:"noChange,omitempty"`
}

type dumpScenarioT struct {
	GoTest           string            `json:"goTest"`
	Scenario         string            `json:"scenario"`
	SubFolder        string            `json:"subFolder"`
	SubScenario      string            `json:"subScenario"`
	CommandLineArgs  *[]string         `json:"commandLineArgs"`
	Files            []dumpFile        `json:"files"`
	FilesFromBuild   *[]string         `json:"filesFromBuild,omitempty"`
	Cwd              string            `json:"cwd,omitempty"`
	Env              map[string]string `json:"env,omitempty"`
	IgnoreCase       bool              `json:"ignoreCase,omitempty"`
	WindowsStyleRoot string            `json:"windowsStyleRoot,omitempty"`
	Edits            *[]dumpEdit       `json:"edits,omitempty"`
}

var (
	dumpMu  sync.Mutex
	dumpOut []dumpScenarioT
)

const fromBuildKey = "\x00GetFileMapWithBuild\x00"

func dumpScenario(t *testing.T, test *tscInput, scenario string) bool {
	out := os.Getenv("TSCTESTS_DUMP")
	if out == "" {
		return false
	}
	goTest := t.Name()
	if i := strings.Index(goTest, "/"); i >= 0 {
		goTest = goTest[:i]
	}
	d := dumpScenarioT{
		GoTest:           goTest,
		Scenario:         scenario,
		SubFolder:        test.getBaselineSubFolder(),
		SubScenario:      test.subScenario,
		Cwd:              test.cwd,
		Env:              test.env,
		IgnoreCase:       test.ignoreCase,
		WindowsStyleRoot: test.windowsStyleRoot,
	}
	if test.commandLineArgs != nil {
		args := append([]string{}, test.commandLineArgs...)
		d.CommandLineArgs = &args
	}
	keys := make([]string, 0, len(test.files))
	for k := range test.files {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := test.files[k]
		if k == fromBuildKey {
			args := v.([]string)
			d.FilesFromBuild = &args
			continue
		}
		switch v := v.(type) {
		case string:
			d.Files = append(d.Files, dumpFile{Path: k, Data: v})
		case *fstest.MapFile:
			if v.Mode&fs.ModeSymlink == 0 || v.Mode != fs.ModeSymlink || !v.ModTime.IsZero() {
				panic(fmt.Sprintf("unsupported MapFile %s", k))
			}
			d.Files = append(d.Files, dumpFile{Path: k, Symlink: true, Data: string(v.Data)})
		default:
			panic(fmt.Sprintf("unsupported file type %T for %s", v, k))
		}
	}
	if test.edits != nil {
		edits := []dumpEdit{}
		for _, e := range test.edits {
			de := dumpEdit{Caption: e.caption, ExpectedDiff: e.expectedDiff, NoChange: e == noChange}
			if e.commandLineArgs != nil {
				args := append([]string{}, e.commandLineArgs...)
				de.CommandLineArgs = &args
			}
			if e.edit != nil {
				// Edits may branch on sys.forIncrementalCorrectness: record both variants.
				record := func(forIncrementalCorrectness bool) [][]any {
					sys := &TestSys{recorder: &recorder{}, fs: &testFs{}, forIncrementalCorrectness: forIncrementalCorrectness}
					e.edit(sys)
					ops := sys.recorder.ops
					if ops == nil {
						ops = [][]any{}
					}
					return ops
				}
				ops := record(false)
				de.Ops = &ops
				opsForIncrementalCorrectness := record(true)
				a, _ := json.Marshal(ops)
				b, _ := json.Marshal(opsForIncrementalCorrectness)
				if string(a) != string(b) {
					de.OpsForIncrementalCorrectness = &opsForIncrementalCorrectness
				}
			}
			edits = append(edits, de)
		}
		d.Edits = &edits
	}
	dumpMu.Lock()
	defer dumpMu.Unlock()
	dumpOut = append(dumpOut, d)
	data, err := json.MarshalIndent(dumpOut, "", " ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(out, data, 0o644); err != nil {
		panic(err)
	}
	return true
}
