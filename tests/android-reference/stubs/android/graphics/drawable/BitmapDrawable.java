package android.graphics.drawable;

import android.graphics.Bitmap;

public class BitmapDrawable extends Drawable {
    private final Bitmap bitmap;

    public BitmapDrawable(Bitmap bitmap) {
        this.bitmap = bitmap;
    }

    public Bitmap getBitmap() {
        return bitmap;
    }
}
