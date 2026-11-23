package io.github.sxpsimon.handwriting;

import java.io.File;
import java.util.concurrent.Callable;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

/** Verification and settings round-trips for one attachment. Host entry points run on the UI thread. */
final class ApkInstallSession implements AutoCloseable {
    private static final AtomicInteger NEXT_PERMISSION_CODE = new AtomicInteger(7821);
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Executor ui;
    private int permissionCode = -1;

    ApkInstallSession(Executor ui) {
        this.ui = ui;
    }

    void verify(Callable<File> validate, Consumer<File> install, Consumer<Exception> fail) {
        worker.execute(() -> {
            final File file;
            try {
                file = validate.call();
            } catch (Exception error) {
                ui.execute(() -> {
                    if (!worker.isShutdown()) fail.accept(error);
                });
                return;
            }
            ui.execute(() -> {
                if (worker.isShutdown()) return;
                try {
                    install.accept(file);
                } catch (Exception error) {
                    fail.accept(error);
                }
            });
        });
    }

    int beginPermissionRequest() {
        // A replacement Activity can receive the result of the previous Activity's settings request.
        permissionCode = NEXT_PERMISSION_CODE.getAndIncrement() & 0xffff;
        return permissionCode;
    }

    boolean consumePermissionResult(int code) {
        if (permissionCode < 0 || code != permissionCode) return false;
        permissionCode = -1;
        return true;
    }

    @Override
    public void close() {
        permissionCode = -1;
        worker.shutdownNow();
    }
}
