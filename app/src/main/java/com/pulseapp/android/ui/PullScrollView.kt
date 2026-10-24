package com.pulseapp.android.ui

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.ScrollView
import kotlin.math.abs

/**
 * ScrollView con "desliza hacia abajo para actualizar" como WHOOP (24/10). Arriba del todo, al arrastrar hacia abajo el contenido
 * baja (con resistencia) y avisa con [onPull] (0…1+ = cuánto falta para soltar). Al soltar pasado el umbral llama a [onRefresh]
 * y el contenido se queda abierto hasta [finishRefresh].
 */
class PullScrollView @JvmOverloads constructor(ctx: Context, attrs: AttributeSet? = null) : ScrollView(ctx, attrs) {

    var onPull: ((Float) -> Unit)? = null
    var onRefresh: (() -> Unit)? = null
    val threshold = 80f * resources.displayMetrics.density

    private val touchSlop = ViewConfiguration.get(ctx).scaledTouchSlop
    private var startY = 0f
    private var pulling = false
    private var pull = 0f
    var refreshing = false
        private set

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> { startY = ev.y; pulling = false }
            MotionEvent.ACTION_MOVE -> if (!refreshing && scrollY == 0 && ev.y - startY > touchSlop) { pulling = true; return true }
        }
        return super.onInterceptTouchEvent(ev)
    }

    override fun onTouchEvent(ev: MotionEvent): Boolean {
        if (!pulling) {
            if (ev.actionMasked == MotionEvent.ACTION_MOVE && !refreshing && scrollY == 0 && ev.y - startY > touchSlop) pulling = true
            else return super.onTouchEvent(ev)
        }
        when (ev.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                pull = ((ev.y - startY - touchSlop) * 0.5f).coerceAtLeast(0f)
                setContentOffset(pull)
                if (pull <= 0f && abs(ev.y - startY) < touchSlop) pulling = false
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                pulling = false
                if (pull >= threshold && ev.actionMasked == MotionEvent.ACTION_UP) {
                    refreshing = true
                    animateOffset(threshold * 0.8f)
                    onRefresh?.invoke()
                } else animateOffset(0f)
                pull = 0f
            }
        }
        return true
    }

    private fun setContentOffset(v: Float) {
        getChildAt(0)?.translationY = v
        onPull?.invoke(v / threshold)
    }

    private fun animateOffset(to: Float) {
        val child = getChildAt(0) ?: return
        val from = child.translationY
        android.animation.ValueAnimator.ofFloat(from, to).apply {
            duration = 220
            addUpdateListener { setContentOffset(it.animatedValue as Float) }
            start()
        }
    }

    /** Cierra el hueco cuando ha terminado de actualizar. */
    fun finishRefresh() {
        refreshing = false
        animateOffset(0f)
    }
}
