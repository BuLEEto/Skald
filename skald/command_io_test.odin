package skald

// White-box tests for the empty-file read path. nbio sizes its read buffer
// from stat and `prep_read` asserts `len(buf) > 0`, so a 0-byte file aborted
// the process. Empty regular files short-circuit before nbio sees them, so
// these run headlessly with no event loop.

import "core:nbio"
import "core:os"
import "core:testing"

@(private = "file")
Io_Msg :: struct {
	path: string,
	n:    int,
	err:  nbio.FS_Error,
}

@(private = "file")
on_read :: proc(r: File_Read_Result) -> Io_Msg {
	return Io_Msg{path = r.path, n = len(r.bytes), err = r.err}
}

@(private = "file")
scratch_dir :: proc() -> string {
	dir, _ := os.temp_directory(context.temp_allocator)
	return dir
}

// Write `contents` to a scratch path under the OS temp dir and return it.
@(private = "file")
scratch_file :: proc(name: string, contents: string) -> string {
	path, _ := os.join_path({scratch_dir(), name}, context.temp_allocator)
	_ = os.write_entire_file(path, contents)
	return path
}

@(test)
empty_regular_file_is_detected :: proc(t: ^testing.T) {
	empty := scratch_file("skald_io_empty.md", "")
	full  := scratch_file("skald_io_full.md", "hello")

	testing.expect(t, read_is_empty_regular(empty), "0-byte regular file should short-circuit")
	testing.expect(t, !read_is_empty_regular(full), "non-empty file must go down the nbio path")

	// A stat failure must NOT short-circuit: nbio still owns the error so
	// the app gets a real .Not_Found rather than a bogus empty success.
	testing.expect(t, !read_is_empty_regular("/nonexistent/skald/nope.md"),
		"missing path must fall through to nbio")

	// Directories stat with a size but aren't .Regular; nbio reports
	// .Unsupported for them and must keep doing so.
	testing.expect(t, !read_is_empty_regular(scratch_dir()),
		"directory must fall through to nbio")
}

@(test)
empty_file_read_completes_successfully :: proc(t: ^testing.T) {
	path := scratch_file("skald_io_empty_e2e.md", "")

	io: Io_State(Io_Msg)
	io_state_init(&io, nil)
	defer io_state_destroy(&io)

	op := new(Async_Op(Io_Msg), context.temp_allocator)
	op^ = Async_Read_File(Io_Msg){path = path, on_result = on_read}
	process_async(op, &io)

	// Completed inline — no nbio op was scheduled, which is the whole
	// point: reaching nbio here would abort the process.
	testing.expect_value(t, len(io.reads), 1)
	testing.expect(t, io.reads[0].pending.done, "empty read should complete without nbio")

	msgs := make([dynamic]Io_Msg, context.temp_allocator)
	drain_io(&io, &msgs)

	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].n, 0)
	testing.expect_value(t, msgs[0].err, nbio.FS_Error.None)
	testing.expect_value(t, msgs[0].path, path)
	testing.expect_value(t, len(io.reads), 0)
}
