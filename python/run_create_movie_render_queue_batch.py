"""Select generated LevelSequences and build BEDLAM MRQ jobs split across
multiple MRQ_Batch_NN assets, then exit UE.

Unlike run_create_movie_render_queue.py (which packs every sequence into a
single MRQ_Batch_00 asset), this script divides the expected sequences across
BEDLAM_MRQ_NUM_BATCHES assets so scripts/run_ue53_bedlam_render_batch.sh can
render each batch in its own UnrealEditor process, restarting between
batches. BEDLAM_MRQ_START_SEQUENCE_INDEX skips that many already-generated
sequences (sorted by name) from the front of the list, for resuming a render
that was interrupted partway through.
"""

import os
import json
import time
import traceback

import unreal


GENERATOR = os.path.abspath(os.environ["BEDLAM_MRQ_GENERATOR_SCRIPT"])
SEQUENCE_ROOT = "/Game/Bedlam/LevelSequences"
OUTPUT_DIR = os.path.abspath(os.environ["BEDLAM_MRQ_OUTPUT_DIR"])
PRESET = os.environ.get("BEDLAM_MRQ_PRESET", "1-1-1_EXR_PNG_DepthMask")
RESOLUTION = os.environ.get("BEDLAM_MRQ_RESOLUTION", "1280x720")
LEGACY_MOTION_BLUR = os.environ.get("BEDLAM_MRQ_LEGACY_MOTION_BLUR", "false").strip().lower()
if LEGACY_MOTION_BLUR not in ("true", "false"):
    raise RuntimeError(
        "BEDLAM_MRQ_LEGACY_MOTION_BLUR must be 'true' or 'false', got: "
        f"{LEGACY_MOTION_BLUR}"
    )
LEGACY_MOTION_BLUR = LEGACY_MOTION_BLUR == "true"
START_DELAY = float(os.environ.get("BEDLAM_MRQ_START_DELAY", "5"))
START_TIMEOUT = float(os.environ.get("BEDLAM_MRQ_START_TIMEOUT", "180"))
EXPECTED_MAP = os.environ.get("BEDLAM_MRQ_EXPECTED_MAP", "").split(".", 1)[0]
STATUS_PATH = os.path.abspath(os.environ["BEDLAM_MRQ_STATUS_PATH"])
LEVEL_SEQUENCE_STATUS = os.path.abspath(
    os.environ["BEDLAM_MRQ_LEVEL_SEQUENCE_STATUS"]
)
NUM_BATCHES = int(os.environ.get("BEDLAM_MRQ_NUM_BATCHES", "1"))
if NUM_BATCHES < 1:
    raise RuntimeError(f"BEDLAM_MRQ_NUM_BATCHES must be >= 1, got: {NUM_BATCHES}")
START_SEQUENCE_INDEX = int(os.environ.get("BEDLAM_MRQ_START_SEQUENCE_INDEX", "0"))
if START_SEQUENCE_INDEX < 0:
    raise RuntimeError(
        f"BEDLAM_MRQ_START_SEQUENCE_INDEX must be >= 0, got: {START_SEQUENCE_INDEX}"
    )

started_at = time.monotonic()
state = {"handle": None, "started": False}


def write_status(status, **values):
    os.makedirs(os.path.dirname(STATUS_PATH), exist_ok=True)
    payload = {
        "status": status,
        "generator_script": GENERATOR,
        "sequence_root": SEQUENCE_ROOT,
        "output_dir": OUTPUT_DIR,
        "preset": PRESET,
        "resolution": RESOLUTION,
        "legacy_motion_blur": LEGACY_MOTION_BLUR,
        "num_batches_requested": NUM_BATCHES,
        "start_sequence_index": START_SEQUENCE_INDEX,
    }
    payload.update(values)
    with open(STATUS_PATH, "w", encoding="utf-8") as output_file:
        json.dump(payload, output_file, indent=2)


def expected_sequence_names():
    with open(LEVEL_SEQUENCE_STATUS, encoding="utf-8") as status_file:
        status = json.load(status_file)
    if status.get("status") != "complete":
        raise RuntimeError(
            f"Level Sequence status is not complete: {LEVEL_SEQUENCE_STATUS}"
        )
    names = list(status.get("expected_sequences") or [])
    if not names:
        raise RuntimeError(
            f"Level Sequence status contains no expected sequences: {LEVEL_SEQUENCE_STATUS}"
        )
    return names


def quit_editor():
    world = unreal.get_editor_subsystem(unreal.UnrealEditorSubsystem).get_editor_world()
    unreal.SystemLibrary.execute_console_command(world, "QUIT_EDITOR")


def generation_readiness():
    """Return whether the requested map and its LevelSequences are fully discoverable."""
    try:
        asset_registry = unreal.AssetRegistryHelpers.get_asset_registry()
        if asset_registry.is_loading_assets():
            return False, "asset registry is still loading"

        world = unreal.get_editor_subsystem(
            unreal.UnrealEditorSubsystem
        ).get_editor_world()
        if world is None:
            return False, "editor world is unavailable"

        levels = unreal.EditorLevelUtils.get_levels(world)
        if not levels:
            return False, "editor world has no loaded levels"
        current_map = str(
            unreal.SystemLibrary.get_path_name(
                unreal.SystemLibrary.get_outer_object(levels[0])
            )
        ).split(".", 1)[0]
        if EXPECTED_MAP and current_map != EXPECTED_MAP:
            return False, f"current map is {current_map}, expected {EXPECTED_MAP}"

        expected_names = expected_sequence_names()
        expected_paths = {
            f"{SEQUENCE_ROOT.rstrip('/')}/{name}" for name in expected_names
        }
        assets = list(
            unreal.EditorAssetLibrary.list_assets(
                SEQUENCE_ROOT, recursive=False, include_folder=False
            )
        )
        sequence_assets = sorted(
            path
            for path in assets
            if str(path).split(".", 1)[0] in expected_paths
            if unreal.EditorAssetLibrary.find_asset_data(path).get_class()
            == unreal.LevelSequence.static_class()
        )
        found_names = {
            str(path).rsplit("/", 1)[-1].split(".", 1)[0]
            for path in sequence_assets
        }
        missing = sorted(set(expected_names) - found_names)
        if missing:
            return False, f"missing expected LevelSequences: {missing}"
        return True, (sequence_assets, expected_names)
    except Exception as exc:
        return False, f"readiness check failed: {exc}"


def batch_ranges(total, num_batches):
    """Split `total` items across `num_batches` as evenly as possible.

    Returns a list of (start, end) index pairs. Requesting more batches than
    remaining items caps the batch count at `total` rather than creating
    empty batches.
    """
    num_batches = min(num_batches, total)
    base_size, remainder = divmod(total, num_batches)
    ranges = []
    start = 0
    for batch_index in range(num_batches):
        size = base_size + (1 if batch_index < remainder else 0)
        ranges.append((start, start + size))
        start += size
    return ranges


def delete_existing_batch_assets(movie_render_queue_root):
    """Remove stale MRQ_Batch_* assets left over from a previous, differently
    sized batch run so the render script never picks up an out-of-date batch.
    """
    root = movie_render_queue_root.rstrip("/")
    for path in list(
        unreal.EditorAssetLibrary.list_assets(root, recursive=False, include_folder=False)
    ):
        asset_name = str(path).rsplit("/", 1)[-1].split(".", 1)[0]
        if asset_name.startswith("MRQ_Batch_"):
            unreal.log(f"[linux-mrq-batch-wrapper] deleting stale batch asset: {path}")
            unreal.EditorAssetLibrary.delete_asset(str(path).split(".", 1)[0])


def tick(_delta_seconds):
    if state["started"]:
        return
    elapsed = time.monotonic() - started_at
    if elapsed < START_DELAY:
        return

    ready, readiness_result = generation_readiness()
    if not ready:
        if elapsed < START_TIMEOUT:
            return
        state["started"] = True
        unreal.unregister_slate_post_tick_callback(state["handle"])
        state["handle"] = None
        message = (
            f"Timed out after {elapsed:.1f}s waiting for MRQ generation readiness: "
            f"{readiness_result}"
        )
        unreal.log_error(f"[linux-mrq-batch-wrapper] {message}")
        write_status("failed", message=message)
        quit_editor()
        return

    state["started"] = True
    unreal.unregister_slate_post_tick_callback(state["handle"])
    state["handle"] = None

    try:
        sequence_assets, expected_names = readiness_result
        write_status("running", expected_sequences=expected_names)

        os.makedirs(OUTPUT_DIR, exist_ok=True)
        namespace = {"__name__": "bedlam_mrq_batch_generator", "__file__": GENERATOR}
        with open(GENERATOR, encoding="utf-8") as script_file:
            exec(compile(script_file.read(), GENERATOR, "exec"), namespace)

        preset_parts = PRESET.split("_")
        sampling = preset_parts[0].split("-")
        if len(sampling) != 3:
            raise RuntimeError(f"Invalid BEDLAM MRQ preset: {PRESET}")
        frame_step, spatial_samples, temporal_samples = map(int, sampling)
        width, height = map(int, RESOLUTION.lower().split("x", 1))
        generate_image = "EXR" in preset_parts or "PNG" in preset_parts
        generate_depth = (
            "DepthMask" in preset_parts or "DepthMaskNormals" in preset_parts
        )
        jobs_per_sequence = int(generate_image) + int(generate_depth)
        if jobs_per_sequence == 0:
            raise RuntimeError(
                f"Preset requests no supported render passes: {PRESET}"
            )

        if START_SEQUENCE_INDEX >= len(sequence_assets):
            raise RuntimeError(
                f"BEDLAM_MRQ_START_SEQUENCE_INDEX={START_SEQUENCE_INDEX} is >= "
                f"the number of available sequences ({len(sequence_assets)})"
            )
        remaining_sequences = sequence_assets[START_SEQUENCE_INDEX:]

        subsystem = unreal.get_editor_subsystem(unreal.MoviePipelineQueueSubsystem)
        pipeline_queue = subsystem.get_queue()
        for job in list(pipeline_queue.get_jobs()):
            pipeline_queue.delete_job(job)

        movie_render_queue_root = namespace["movie_render_queue_root"]
        delete_existing_batch_assets(movie_render_queue_root)

        ranges = batch_ranges(len(remaining_sequences), NUM_BATCHES)
        namespace["output_dir"] = OUTPUT_DIR
        batches = []
        for batch_index, (range_start, range_end) in enumerate(ranges):
            batch_sequences = remaining_sequences[range_start:range_end]
            for sequence_path in batch_sequences:
                asset_data = unreal.EditorAssetLibrary.find_asset_data(sequence_path)
                if "EXR" in preset_parts:
                    namespace["add_render_job_exr_image"](
                        pipeline_queue,
                        asset_data,
                        frame_step,
                        (width, height),
                        spatial_samples,
                        temporal_samples,
                        LEGACY_MOTION_BLUR,
                    )
                if "PNG" in preset_parts and "EXR" not in preset_parts:
                    namespace["add_render_job"](
                        pipeline_queue,
                        asset_data,
                        frame_step,
                        (width, height),
                        spatial_samples,
                        temporal_samples,
                        LEGACY_MOTION_BLUR,
                    )
                if "DepthMaskNormals" in preset_parts:
                    namespace["add_render_job_exr_depthmask"](
                        pipeline_queue,
                        asset_data,
                        frame_step,
                        (width, height),
                        "WorldSpace",
                        LEGACY_MOTION_BLUR,
                    )
                elif "DepthMask" in preset_parts:
                    namespace["add_render_job_exr_depthmask"](
                        pipeline_queue,
                        asset_data,
                        frame_step,
                        (width, height),
                        None,
                        LEGACY_MOTION_BLUR,
                    )

            namespace["save_movie_render_queue"](
                pipeline_queue,
                batch_index,
                movie_render_queue_root,
                namespace["movie_render_queue_template"],
            )
            expected_batch_jobs = len(batch_sequences) * jobs_per_sequence
            if len(pipeline_queue.get_jobs()) != expected_batch_jobs:
                raise RuntimeError(
                    f"Batch {batch_index}: expected {expected_batch_jobs} MRQ jobs, "
                    f"found {len(pipeline_queue.get_jobs())}"
                )

            mrq_path = movie_render_queue_root.rstrip("/") + f"/MRQ_Batch_{batch_index:02d}"
            if not unreal.EditorAssetLibrary.does_asset_exist(mrq_path):
                raise RuntimeError(f"Saved MRQ asset does not exist: {mrq_path}")

            batches.append(
                {
                    "index": batch_index,
                    "mrq_asset": mrq_path,
                    "sequence_count": len(batch_sequences),
                    "job_count": expected_batch_jobs,
                    "sequences": [
                        str(p).rsplit("/", 1)[-1].split(".", 1)[0] for p in batch_sequences
                    ],
                }
            )
            unreal.log(
                f"[linux-mrq-batch-wrapper] batch {batch_index}: "
                f"{len(batch_sequences)} sequences, {expected_batch_jobs} jobs -> {mrq_path}"
            )

            # Clear jobs before starting the next batch so they don't
            # accumulate in the live pipeline queue across every iteration.
            for job in list(pipeline_queue.get_jobs()):
                pipeline_queue.delete_job(job)

        total_jobs = sum(batch["job_count"] for batch in batches)
        write_status(
            "complete",
            expected_sequences=expected_names,
            total_sequences=len(remaining_sequences),
            total_jobs=total_jobs,
            num_batches=len(batches),
            batches=batches,
        )

        unreal.log(
            f"[linux-mrq-batch-wrapper] generated {len(batches)} batches from "
            f"{len(remaining_sequences)} sequences (start_index={START_SEQUENCE_INDEX}) "
            f"preset={PRESET} resolution={RESOLUTION} total_jobs={total_jobs} "
            f"legacy_motion_blur={LEGACY_MOTION_BLUR}"
        )
    except BaseException as exc:
        unreal.log_error(f"[linux-mrq-batch-wrapper] failed: {exc}\n{traceback.format_exc()}")
        write_status("failed", message=str(exc))
    finally:
        quit_editor()


state["handle"] = unreal.register_slate_post_tick_callback(tick)
unreal._linux_mrq_batch_generation_handle = state["handle"]
write_status("waiting_for_readiness")
unreal.log(
    f"[linux-mrq-batch-wrapper] waiting for map={EXPECTED_MAP or '<any>'}, "
    f"asset registry, and LevelSequences; minimum_delay={START_DELAY:.1f}s "
    f"timeout={START_TIMEOUT:.1f}s; num_batches={NUM_BATCHES} "
    f"start_sequence_index={START_SEQUENCE_INDEX}"
)
