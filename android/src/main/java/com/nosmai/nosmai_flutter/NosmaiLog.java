package com.nosmai.nosmai_flutter;

import android.util.Log;
import com.nosmai.nosmai_effects_sdk.BuildConfig;

final class NosmaiLog {
    private NosmaiLog() {}

    static int d(String tag, String message) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.d(tag, message) : 0;
    }

    static int d(String tag, String message, Throwable error) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.d(tag, message, error) : 0;
    }

    static int i(String tag, String message) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.i(tag, message) : 0;
    }

    static int i(String tag, String message, Throwable error) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.i(tag, message, error) : 0;
    }

    static int w(String tag, String message) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.w(tag, message) : 0;
    }

    static int w(String tag, String message, Throwable error) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.w(tag, message, error) : 0;
    }

    static int e(String tag, String message) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.e(tag, message) : 0;
    }

    static int e(String tag, String message, Throwable error) {
        return BuildConfig.NOSMAI_INTERNAL_LOGS ? Log.e(tag, message, error) : 0;
    }
}
