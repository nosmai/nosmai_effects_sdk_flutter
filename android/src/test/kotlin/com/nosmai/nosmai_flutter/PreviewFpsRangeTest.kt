package com.nosmai.nosmai_flutter

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class PreviewFpsRangeTest {
    @Test fun prefersExposureHeadroomAtThirty() {
        assertTrue(Camera2Helper.compareFpsRanges(15, 30, 30, 30) < 0)
        assertTrue(Camera2Helper.compareFpsRanges(10, 30, 15, 30) < 0)
        assertTrue(Camera2Helper.compareFpsRanges(15, 30, 15, 60) < 0)
        assertEquals(0, Camera2Helper.compareFpsRanges(15, 30, 15, 30))
    }

    @Test fun handlesCamerasWithoutAnAdaptiveThirtyFpsRange() {
        assertTrue(Camera2Helper.compareFpsRanges(30, 30, 15, 24) < 0)
        assertTrue(Camera2Helper.compareFpsRanges(15, 24, 60, 60) < 0)
        assertTrue(Camera2Helper.compareFpsRanges(15, 24, 15, 20) < 0)
        assertNull(Camera2Helper.selectPreviewFpsRange(emptyArray()))
        assertNull(Camera2Helper.selectPreviewFpsRange(null))
    }
}
